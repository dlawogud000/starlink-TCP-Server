// tcp_ping_sender.c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/tcp.h>

#define PING_MAGIC 0x50494E47u
#define MAX_PROBES 10000000ULL

typedef struct {
    uint32_t magic;
    uint64_t seq;
    uint64_t send_ns;
} __attribute__((packed)) ping_pkt_t;

typedef struct {
    uint64_t send_ns;
    int valid;
    int replied;
} probe_entry_t;

static int listen_fd;
static int conn_fd;

static FILE *fp;
static probe_entry_t *table;

static uint64_t total_probes;
static int interval_ms;
static volatile sig_atomic_t running = 1;

static pthread_mutex_t table_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static void sleep_until_ns(uint64_t target_ns) {
    struct timespec ts;
    ts.tv_sec = target_ns / 1000000000ULL;
    ts.tv_nsec = target_ns % 1000000000ULL;

    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) == EINTR) {
        if (!running) break;
    }
}

static void handle_sigint(int signo) {
    (void)signo;
    running = 0;
}

static void log_line(const char *fmt,
                     uint64_t seq,
                     uint64_t send_ns,
                     uint64_t recv_ns,
                     double rtt_ms,
                     const char *status) {
    pthread_mutex_lock(&log_lock);
    fprintf(fp, fmt, seq, send_ns, recv_ns, rtt_ms, status);
    fflush(fp);
    pthread_mutex_unlock(&log_lock);
}

static ssize_t write_all(int fd, const void *buf, size_t len) {
    const char *p = (const char *)buf;
    size_t left = len;

    while (left > 0) {
        ssize_t n = send(fd, p, left, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;

        p += n;
        left -= n;
    }

    return len;
}

static ssize_t read_all(int fd, void *buf, size_t len) {
    char *p = (char *)buf;
    size_t left = len;

    while (left > 0) {
        ssize_t n = recv(fd, p, left, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return 0;

        p += n;
        left -= n;
    }

    return len;
}

void *sender_thread(void *arg) {
    (void)arg;

    uint64_t interval_ns = (uint64_t)interval_ms * 1000000ULL;
    uint64_t next_send_ns = now_ns();

    for (uint64_t seq = 0; seq < total_probes && running; seq++) {
        sleep_until_ns(next_send_ns);
        if (!running) break;

        ping_pkt_t pkt;
        pkt.magic = PING_MAGIC;
        pkt.seq = seq;
        pkt.send_ns = now_ns();

        pthread_mutex_lock(&table_lock);
        table[seq].send_ns = pkt.send_ns;
        table[seq].valid = 1;
        table[seq].replied = 0;
        pthread_mutex_unlock(&table_lock);

        if (write_all(conn_fd, &pkt, sizeof(pkt)) < 0) {
            log_line("%lu,%lu,%lu,%.3f,%s\n",
                     seq, pkt.send_ns, 0, 0.0, "send_error");
            running = 0;
            break;
        }

        next_send_ns += interval_ns;
    }

    return NULL;
}

void *receiver_thread(void *arg) {
    (void)arg;

    while (running) {
        ping_pkt_t reply;
        ssize_t n = read_all(conn_fd, &reply, sizeof(reply));

        if (n < 0) {
            if (!running) break;

            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }

            perror("recv");
            running = 0;
            break;
        }

        if (n == 0) {
            running = 0;
            break;
        }

        if (reply.magic != PING_MAGIC) {
            continue;
        }

        uint64_t recv_ns = now_ns();
        uint64_t seq = reply.seq;

        if (seq >= total_probes) {
            log_line("%lu,%lu,%lu,%.3f,%s\n",
                     seq, 0, recv_ns, 0.0, "seq_out_of_range");
            continue;
        }

        uint64_t send_ns = 0;
        int valid = 0;
        int already_replied = 0;

        pthread_mutex_lock(&table_lock);

        valid = table[seq].valid;
        already_replied = table[seq].replied;

        if (valid && !already_replied) {
            send_ns = table[seq].send_ns;
            table[seq].replied = 1;
        }

        pthread_mutex_unlock(&table_lock);

        if (valid && !already_replied) {
            double rtt_ms = (recv_ns - send_ns) / 1000000.0;
            log_line("%lu,%lu,%lu,%.3f,%s\n",
                     seq, send_ns, recv_ns, rtt_ms, "ok");
        } else {
            log_line("%lu,%lu,%lu,%.3f,%s\n",
                     seq, 0, recv_ns, 0.0, "duplicate_or_unknown");
        }
    }

    return NULL;
}

int main(int argc, char *argv[]) {
    if (argc != 5) {
        fprintf(stderr,
                "Usage: %s <listen_port> <interval_ms> <duration_sec> <output_csv>\n",
                argv[0]);
        fprintf(stderr,
                "Example: %s 30000 10 300 server_rtt.csv\n",
                argv[0]);
        return 1;
    }

    signal(SIGINT, handle_sigint);

    int port = atoi(argv[1]);
    interval_ms = atoi(argv[2]);
    int duration_sec = atoi(argv[3]);
    const char *out_path = argv[4];

    if (interval_ms <= 0 || duration_sec <= 0) {
        fprintf(stderr, "interval_ms and duration_sec must be positive\n");
        return 1;
    }

    total_probes = ((uint64_t)duration_sec * 1000ULL) / (uint64_t)interval_ms;

    if (total_probes == 0 || total_probes > MAX_PROBES) {
        fprintf(stderr, "Invalid number of probes: %lu\n", total_probes);
        return 1;
    }

    table = calloc(total_probes, sizeof(probe_entry_t));
    if (!table) {
        perror("calloc");
        return 1;
    }

    fp = fopen(out_path, "w");
    if (!fp) {
        perror("fopen");
        free(table);
        return 1;
    }

    fprintf(fp, "seq,send_ns,recv_ns,rtt_ms,status\n");
    fflush(fp);

    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        perror("socket");
        fclose(fp);
        free(table);
        return 1;
    }

    int yes = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in bind_addr = {0};
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_addr.s_addr = INADDR_ANY;
    bind_addr.sin_port = htons(port);

    if (bind(listen_fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
        perror("bind");
        close(listen_fd);
        fclose(fp);
        free(table);
        return 1;
    }

    if (listen(listen_fd, 1) < 0) {
        perror("listen");
        close(listen_fd);
        fclose(fp);
        free(table);
        return 1;
    }

    printf("Waiting for TCP client on port %d...\n", port);

    struct sockaddr_in client_addr;
    socklen_t client_len = sizeof(client_addr);

    conn_fd = accept(listen_fd, (struct sockaddr *)&client_addr, &client_len);
    if (conn_fd < 0) {
        perror("accept");
        close(listen_fd);
        fclose(fp);
        free(table);
        return 1;
    }

    int one = 1;
    setsockopt(conn_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct timeval rcv_timeout;
    rcv_timeout.tv_sec = 0;
    rcv_timeout.tv_usec = 100000;

    if (setsockopt(conn_fd, SOL_SOCKET, SO_RCVTIMEO,
                   &rcv_timeout, sizeof(rcv_timeout)) < 0) {
        perror("setsockopt SO_RCVTIMEO");
    }

    char client_ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &client_addr.sin_addr, client_ip, sizeof(client_ip));

    printf("Client connected: %s:%d\n",
           client_ip, ntohs(client_addr.sin_port));

    pthread_t sender;
    pthread_t receiver;

    if (pthread_create(&receiver, NULL, receiver_thread, NULL) != 0) {
        perror("pthread_create receiver");
        close(conn_fd);
        close(listen_fd);
        fclose(fp);
        free(table);
        return 1;
    }

    if (pthread_create(&sender, NULL, sender_thread, NULL) != 0) {
        perror("pthread_create sender");
        running = 0;
        pthread_join(receiver, NULL);
        close(conn_fd);
        close(listen_fd);
        fclose(fp);
        free(table);
        return 1;
    }

    pthread_join(sender, NULL);

    sleep(2);

    running = 0;
    pthread_join(receiver, NULL);

    for (uint64_t seq = 0; seq < total_probes; seq++) {
        int valid;
        int replied;
        uint64_t send_ns;

        pthread_mutex_lock(&table_lock);
        valid = table[seq].valid;
        replied = table[seq].replied;
        send_ns = table[seq].send_ns;
        pthread_mutex_unlock(&table_lock);

        if (valid && !replied) {
            log_line("%lu,%lu,%lu,%.3f,%s\n",
                     seq, send_ns, 0, 0.0, "timeout");
        }
    }

    close(conn_fd);
    close(listen_fd);
    fclose(fp);
    free(table);

    printf("Done. Result saved to %s\n", out_path);

    return 0;
}