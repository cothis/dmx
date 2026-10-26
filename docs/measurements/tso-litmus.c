/* Message-passing litmus for the guest's TSO memory model (scratch tool, not part of dmx).
 *
 * The writer stores data then flag; the reader loads flag then data. data < flag means one of
 * the pairs was reordered, which the Apple CPU's TSO bit (PR_SET_MEM_MODEL_TSO) forbids.
 *   litmus <iterations> <tso|plain> <writer cpu> <reader cpu>
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/prctl.h>

#define PR_SET_MEM_MODEL 0x4d4d444c
#define PR_GET_MEM_MODEL 0x6d4d444c
#define TSO 1

static volatile uint64_t flag __attribute__((aligned(128)));
static volatile uint64_t data __attribute__((aligned(128)));
static long iterations;
static int tso, writer_cpu, reader_cpu;
static volatile int ready;

static int pin(int cpu) {
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	if (sched_setaffinity(0, sizeof(set), &set) != 0) {
		return -1;
	}
	if (tso && prctl(PR_SET_MEM_MODEL, TSO, 0, 0, 0) != 0) {
		return -1;
	}
	return prctl(PR_GET_MEM_MODEL, 0, 0, 0, 0);
}

static void *writer(void *arg) {
	long model = pin(writer_cpu);
	ready = 1;
	for (long i = 1; i <= iterations; ++i) {
		data = i;
		flag = i;
	}
	return (void *)model;
}

int main(int argc, char **argv) {
	if (argc != 5) {
		fprintf(stderr, "usage: %s <iterations> <tso|plain> <writer cpu> <reader cpu>\n", argv[0]);
		return 2;
	}
	iterations = atol(argv[1]);
	tso = argv[2][0] == 't';
	writer_cpu = atoi(argv[3]);
	reader_cpu = atoi(argv[4]);

	pthread_t thread;
	if (pthread_create(&thread, NULL, writer, NULL) != 0) {
		return 1;
	}
	long reader_model = pin(reader_cpu);
	while (!ready) {
	}
	long bad = 0;
	for (long i = 0; i < iterations; ++i) {
		uint64_t f = flag;
		uint64_t d = data;
		if (d < f) {
			++bad;
		}
	}
	void *writer_model;
	pthread_join(thread, &writer_model);
	printf("reorderings=%ld writer_model=%ld reader_model=%ld writer_cpu=%d reader_cpu=%d\n",
	       bad, (long)writer_model, reader_model, writer_cpu, reader_cpu);
	return 0;
}
