#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>

typedef struct
{
    pthread_mutex_t lock;
    long int critical_count;
    volatile long int scratchpad;
} d_struct;
d_struct tdata;

typedef struct
{
    clock_t end;
    unsigned int idle_loops;
} thread_param;
thread_param tparam;

void display_help(int exitcode, const char* errormsg)
{
    if(errormsg != 0)
        printf("Error: %s\n", errormsg);

    printf("Accepted Arguments:\n");
    printf("-h : print help\n");
    printf("-t i{threads} : test thread count\n");
    printf("-d i{duration} : duration in seconds\n");

    exit(exitcode);
}

static void* procedure(thread_param* param)
{
    int err;
    int terminate = 0;

    while((clock() < param->end) & !terminate)
    { 
        if((err = pthread_mutex_lock(&tdata.lock)) != 0)
        {
            printf("Mutex lock returned error code %d, exiting thread", err);
            terminate = 1;
        }
        else
        {
            if(clock() > param->end){
                pthread_mutex_unlock(&tdata.lock);
                break;
            }
            tdata.critical_count += 1;
            for(unsigned int i = 0; i < param->idle_loops; i++) tdata.scratchpad ++;
            pthread_mutex_unlock(&tdata.lock);
        }
    }
    return 0; 
}

int main(int argc, char *argv[])
{
    int threads = 0;
    int duration = 10;
    clock_t endpoint;

    int opt;
    while((opt = getopt(argc, argv, "ht:d:")) != -1)
    {
        switch(opt)
        {
        case 'h':
            display_help(0, 0);
            break;
        case 't':
            threads = atoi(optarg);
            if(threads <= 0) display_help(-1, "Thread count must be a positive integer"); 
            break;
        case 'd':
            duration = atoi(optarg);
            if(duration <= 0) display_help(-1, "Duration must be a positive integer");
            break;
        default:
            display_help(-1, "Arg list not valid");
            break;
        }
    }
    if(threads == 0) display_help(-1, "-t is a required argument");
    
    //printf("Executing semaphore contention test for %d seconds\n", duration);
    endpoint = clock() + duration * CLOCKS_PER_SEC;

    pthread_mutex_init(&tdata.lock, 0);
    pthread_t threadlist[threads];
    tparam.end = endpoint;
    tparam.idle_loops = 2000;

    tdata.critical_count = 0;
    tdata.scratchpad = 0;

    for(int i = 1; i < threads; i++) pthread_create(&threadlist[i], 0, procedure, &tparam);
    procedure(&tparam);
    for(int i = 1; i < threads; i++) pthread_join(threadlist[i], 0);
    
    pthread_mutex_destroy(&tdata.lock);

    printf("%d, %ld, %ld\n", threads, tdata.critical_count, tdata.scratchpad);

    return 0;
}
