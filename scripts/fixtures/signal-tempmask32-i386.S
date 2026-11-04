/* The 32-bit ppoll and pselect6, which FEX implements itself, with a mask of their own. With SIGUSR1 blocked and
 * queued, each call's mask lets it in: the handler must run during the call, see the call's mask (SIGUSR2 blocked) as
 * its own and the program's mask in its frame, and the call must return EINTR with the program's mask back afterwards.
 * pselect6 with no mask must leave SIGUSR1 blocked and time out. Linux i386 ABI. */
.global _start
.text
_start:
    mov $20, %eax
    int $0x80
    mov %eax, pid
    mov $224, %eax
    int $0x80
    mov %eax, tid
    /* rt_sigaction(SIGUSR1, action, 0, 8) */
    mov $174, %eax
    mov $10, %ebx
    mov $action, %ecx
    xor %edx, %edx
    mov $8, %esi
    int $0x80
    test %eax, %eax
    js fail
    /* rt_sigprocmask(SIG_SETMASK, SIGUSR1, 0, 8) */
    mov $175, %eax
    mov $2, %ebx
    mov $mask_usr1, %ecx
    xor %edx, %edx
    mov $8, %esi
    int $0x80
    /* an empty pipe to wait on */
    mov $42, %eax
    mov $fds, %ebx
    int $0x80
    test %eax, %eax
    js fail
    mov fds, %eax
    mov %eax, pollfd
    movw $1, pollfd+4

    mov $300, %ebp
loop:
    call raise_usr1
    /* ppoll(fds, 1, timeout, mask, 8) */
    mov $309, %eax
    mov $pollfd, %ebx
    mov $1, %ecx
    mov $timeout, %edx
    mov $mask_usr2, %esi
    mov $8, %edi
    int $0x80
    call check

    call raise_usr1
    call set_readset
    /* pselect6(nfds, read, 0, 0, timeout, {mask, 8}) */
    push %ebp
    mov $308, %eax
    mov fds, %ebx
    inc %ebx
    mov $readset, %ecx
    xor %edx, %edx
    xor %esi, %esi
    mov $timeout, %edi
    mov $pselect_arg, %ebp
    int $0x80
    pop %ebp
    call check

    dec %ebp
    jnz loop

    /* No mask: SIGUSR1 stays blocked, and the call just times out. */
    call raise_usr1
    call set_readset
    push %ebp
    mov $308, %eax
    mov fds, %ebx
    inc %ebx
    mov $readset, %ecx
    xor %edx, %edx
    xor %esi, %esi
    mov $short_wait, %edi
    xor %ebp, %ebp
    int $0x80
    pop %ebp
    test %eax, %eax
    jnz fail
    cmpl $0, seen
    jne fail

    mov $4, %eax
    mov $1, %ebx
    mov $good, %ecx
    mov $good_end-good, %edx
    int $0x80
    mov $252, %eax
    xor %ebx, %ebx
    int $0x80

set_readset:
    mov fds, %ecx
    mov $1, %eax
    shl %cl, %eax
    mov %eax, readset
    ret

raise_usr1:
    mov $270, %eax
    mov pid, %ebx
    mov tid, %ecx
    mov $10, %edx
    int $0x80
    test %eax, %eax
    js fail
    ret

/* Whatever the call was, it was interrupted once by the handler, which saw the right masks. */
check:
    cmp $-4, %eax
    jne fail
    cmpl $1, seen
    jne fail
    movl $0, seen
    mov got_mask, %eax
    cmp $(1 << 9) | (1 << 11), %eax
    jne fail
    mov got_frame_mask, %eax
    cmp $1 << 9, %eax
    jne fail
    /* the program's mask is back on the kernel's side */
    mov $175, %eax
    xor %ebx, %ebx
    xor %ecx, %ecx
    mov $now_mask, %edx
    mov $8, %esi
    int $0x80
    mov now_mask, %eax
    cmp $1 << 9, %eax
    jne fail
    ret

/* signal number, siginfo, ucontext above the return address; uc_sigmask is at 108 in the ucontext */
handler:
    incl seen
    mov 12(%esp), %eax
    mov 108(%eax), %eax
    mov %eax, got_frame_mask
    mov $175, %eax
    xor %ebx, %ebx
    xor %ecx, %ecx
    mov $got_mask, %edx
    mov $8, %esi
    int $0x80
    ret
restorer:
    mov $173, %eax
    int $0x80
fail:
    mov $4, %eax
    mov $1, %ebx
    mov $bad, %ecx
    mov $bad_end-bad, %edx
    int $0x80
    mov $252, %eax
    mov $1, %ebx
    int $0x80

.data
.align 4
action:
    .long handler, 0x04000004, restorer, 0, 0
mask_usr1:
    .long 1 << 9, 0
mask_usr2:
    .long 1 << 11, 0
timeout:
    .long 5, 0
short_wait:
    .long 0, 50000000
pselect_arg:
    .long mask_usr2, 8
pollfd:
    .space 8
fds:
    .long 0, 0
readset:
    .space 128
pid:
    .long 0
tid:
    .long 0
seen:
    .long 0
got_mask:
    .long 0, 0
got_frame_mask:
    .long 0
now_mask:
    .long 0, 0
good:
    .ascii "signal-tempmask32-ok\n"
good_end:
bad:
    .ascii "signal-tempmask32-FAILED\n"
bad_end:
