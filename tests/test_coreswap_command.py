#!/usr/bin/env python3
"""Compile the shipping command with mock storage/MMIO; no device access."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'pkgs/uboot-common/cvi-coreswap-cmd.c').read_text()
source = re.sub(r'^#include .*\n', '', source, flags=re.M)
assert source.count('__asm__ volatile ("dsb sy" ::: "memory");') == 3
source = source.replace('__asm__ volatile ("dsb sy" ::: "memory");', 'barriers++;')
source = source[:source.index('U_BOOT_CMD(')]
prelude = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#define __aarch64__ 1
#define ARCH_DMA_MINALIGN 64
#define __aligned(n) __attribute__((aligned(n)))
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define FS_TYPE_FAT 1
#define CMD_RET_SUCCESS 0
#define CMD_RET_FAILURE 1
#define CMD_RET_USAGE 2
typedef uint32_t u32;
struct cmd_tbl { int unused; };
static u32 words[4], chip;
static unsigned writes, barriers, calls, order[8];
static int dev_error, read_error, fail_write;
static const char *files[2], *result, *oldargs;
static char reported[256];
static u32 readl(const volatile void *p) {
 uintptr_t a=(uintptr_t)p;
 if (a==0x0e000004) return chip;
 assert(a>=0x0502601c && a<=0x05026028 && !(a&3));
 return words[(a-0x0502601c)/4];
}
static void writel(u32 value, volatile void *p) {
 unsigned i=((uintptr_t)p-0x0502601c)/4;
 assert(i<2 && writes<8);
 order[writes++]=i;
 if (fail_write != (int)writes) words[i]=value;
}
static uintptr_t map_to_sysmem(void *p) { return (uintptr_t)p; }
static int fs_set_blk_dev(const char *dev,const char *part,int type) {
 assert(!strcmp(dev,"mmc") && !strcmp(part,"0:1") && type==FS_TYPE_FAT);
 return dev_error;
}
static int fs_read(const char *name,uintptr_t dest,loff_t offset,loff_t count,loff_t *actual) {
 int i=!strcmp(name,"/coreswap.pending");
 assert(i || !strcmp(name,"/coreswap.request"));
 assert(offset==0 && count==7 && !(dest%ARCH_DMA_MINALIGN));
 calls++;
 if(read_error || !files[i]) return 1;
 *actual=strlen(files[i]);
 if(*actual>count) *actual=count;
 memcpy((void *)dest,files[i],*actual);
 return 0;
}
static const char *env_get(const char *name) {
 if(!strcmp(name,"nixbadge_coreswap_result")) return result;
 assert(!strcmp(name,"nixbadge_args")); return oldargs;
}
static int env_set(const char *name,const char *value) {
 assert(!strcmp(name,"nixbadge_args"));
 assert(strlen(value)<sizeof(reported)); strcpy(reported,value); return 0;
}
static void reset(void) {
 const u32 defaults[]={0xabcd1234,0xdeadbeef,0xabcd1234,0xdeadbeef};
 memcpy(words,defaults,sizeof(words)); chip=0x4d474e32;
 writes=barriers=calls=0; dev_error=read_error=fail_write=0;
 files[0]=files[1]="riscv\n"; result=oldargs=NULL; reported[0]=0;
}
'''
tests = r'''
int main(void) {
 const char *invalid[]={NULL,"","arm\n","riscv","riscv\nx","riscv\nxxxxxxxxxxxxxxxx"};
 for(unsigned file=0;file<2;file++) for(unsigned i=0;i<ARRAY_SIZE(invalid);i++) {
  reset(); files[file]=invalid[i]; assert(coreswap_request()==1 && writes==0);
 }
 for(unsigned i=0;i<4;i++) {
  reset(); words[i]^=1; assert(coreswap_request()==1 && writes==0);
 }
 reset(); chip=0; assert(coreswap_request()==1 && writes==0 && calls==0);
 reset(); dev_error=1; assert(coreswap_request()==1 && writes==0);
 reset(); read_error=1; assert(coreswap_request()==1 && writes==0);
 reset(); assert(coreswap_request()==0 && writes==2 && calls==2 && barriers==2);
 assert(order[0]==1 && order[1]==0 && words[0]==0x43535731 && words[1]==~words[0]);
 assert(words[2]==0xabcd1234 && words[3]==0xdeadbeef);
 assert(coreswap_request()==1 && writes==2 && calls==4);
 for(int failed=1;failed<=2;failed++) {
  reset(); fail_write=failed; assert(coreswap_request()==1 && writes==4 && barriers==3);
  assert(words[0]==0xabcd1234 && words[1]==0xdeadbeef);
 }
 reset(); char *argv[]={"coreswap","report"};
 assert(do_coreswap(NULL,0,2,argv)==0 && !strcmp(reported," nixbadge.coreswap=disabled"));
 result="ok"; oldargs="root=/dev/test";
 assert(do_coreswap(NULL,0,2,argv)==0 && !strcmp(reported,"root=/dev/test nixbadge.coreswap=ok"));
 result="unknown"; assert(do_coreswap(NULL,0,2,argv)==1);
 char longargs[256]; memset(longargs,'x',255); longargs[255]=0;
 result="timeout"; oldargs=longargs; assert(do_coreswap(NULL,0,2,argv)==1);
 assert(do_coreswap(NULL,0,1,argv)==2);
 puts("PASS shipping coreswap command validation, ordering, rollback and reporting");
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path/'test.c').write_text(prelude + source + tests)
    subprocess.run([os.environ.get('CC', 'cc'), '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', '-fsanitize=undefined,address',
                    str(path/'test.c'), '-o', str(path/'test')], check=True)
    subprocess.run([str(path/'test')], check=True)
