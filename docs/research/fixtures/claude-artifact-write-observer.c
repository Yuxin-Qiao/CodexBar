#include <sys/clonefile.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
static _Atomic unsigned long long submitted = 0;
static _Atomic unsigned clones = 0;
static int is_artifact(int fd) {
 char path[4096];
 return fcntl(fd, F_GETPATH, path) == 0 && strstr(path, "/.claude-cache-") != NULL;
}
static ssize_t observed_pwrite(int fd, const void *buf, size_t n, off_t offset) {
 ssize_t result = pwrite(fd,buf,n,offset);
 if(result > 0 && is_artifact(fd)) atomic_fetch_add(&submitted,(unsigned long long)result);
 return result;
}
static int observed_clone(int source, int directory, const char *target, unsigned flags) {
 if(strstr(target,"/.claude-cache-") && getenv("PROOF_FORCE_FULL_WRITES")) {errno=ENOTSUP;return -1;}
 int result=fclonefileat(source,directory,target,flags);
 if(result == 0 && strstr(target,"/.claude-cache-")) atomic_fetch_add(&clones,1);
 return result;
}
__attribute__((used)) static const struct {const void *replacement;const void *original;} hooks[]
__attribute__((section("__DATA,__interpose"))) = {
 {(void*)observed_pwrite,(void*)pwrite},
 {(void*)observed_clone,(void*)fclonefileat}
};
__attribute__((destructor)) static void report(void) {
 fprintf(stderr,"CLI_WRITE_PROOF submitted=%llu clones=%u\n",atomic_load(&submitted),atomic_load(&clones));
}
