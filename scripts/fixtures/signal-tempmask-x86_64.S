/* ppoll, pselect6 and epoll_pwait with a mask of their own, the way a server waits for a signal it blocks everywhere
 * else. With SIGUSR1 blocked and queued, each call's mask lets it in: the handler must run during the call, see the
 * call's mask (SIGUSR2 blocked) as its own and the program's mask (SIGUSR1 blocked) in its frame, and the call must
 * return EINTR. Afterwards the program's mask is back: SIGUSR1 is blocked again, on the kernel's side too. And a
 * SIGALRM the program allows but the call's mask blocks must wait until the call ends. Linux x86-64 ABI. */
.global _start
.text
_start:
    mov $39, %eax
    syscall
    mov %rax, pid(%rip)
    mov $186, %eax
    syscall
    mov %rax, tid(%rip)
    mov $13, %eax
    mov $10, %edi
    lea usr1_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    /* the program's mask: SIGUSR1 */
    mov $14, %eax
    mov $2, %edi
    lea mask_usr1(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    /* an empty pipe to wait on, and an epoll on it */
    mov $22, %eax
    lea fds(%rip), %rdi
    syscall
    test %rax, %rax
    js fail
    mov $213, %eax
    mov $1, %edi
    syscall
    test %rax, %rax
    js fail
    mov %rax, epfd(%rip)
    mov $233, %eax
    mov epfd(%rip), %rdi
    mov $1, %esi
    mov fds(%rip), %edx
    lea epev(%rip), %r10
    syscall
    test %rax, %rax
    js fail
    mov fds(%rip), %eax
    mov %eax, pollfd(%rip)
    movw $1, pollfd+4(%rip)

    mov $300, %r13d
loop:
    call raise_usr1
    /* ppoll(fds, 1, timeout, mask, 8) */
    mov $271, %eax
    lea pollfd(%rip), %rdi
    mov $1, %esi
    lea timeout(%rip), %rdx
    lea mask_usr2(%rip), %r10
    mov $8, %r8d
    syscall
    call check

    call raise_usr1
    /* pselect6(nfds, read, 0, 0, timeout, {mask, 8}) */
    mov fds(%rip), %ecx
    mov $1, %eax
    shl %cl, %rax
    mov %rax, readset(%rip)
    mov $270, %eax
    mov fds(%rip), %edi
    inc %edi
    lea readset(%rip), %rsi
    xor %edx, %edx
    xor %r10d, %r10d
    lea timeout(%rip), %r8
    lea pselect_arg(%rip), %r9
    syscall
    call check

    call raise_usr1
    /* epoll_pwait(epfd, events, 1, 5000 ms, mask, 8) */
    mov $281, %eax
    mov epfd(%rip), %rdi
    lea epout(%rip), %rsi
    mov $1, %edx
    mov $5000, %r10d
    lea mask_usr2(%rip), %r8
    mov $8, %r9d
    syscall
    call check

    dec %r13d
    jnz loop

    /* A signal the program allows and the call's mask blocks waits for the end of the call. */
    mov $13, %eax
    mov $14, %edi
    lea alarm_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $38, %eax
    xor %edi, %edi
    lea alarm_timer(%rip), %rsi
    xor %edx, %edx
    syscall
    test %rax, %rax
    js fail
    mov $271, %eax
    lea pollfd(%rip), %rdi
    mov $1, %esi
    lea short_wait(%rip), %rdx
    lea mask_alarm(%rip), %r10
    mov $8, %r8d
    syscall
    test %rax, %rax
    jnz fail
    /* it comes as the call ends, and qemu takes it at its next system call */
    mov $39, %eax
    syscall
    cmpq $1, alarm_count(%rip)
    jne fail

    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $good_end-good, %edx
    syscall
    mov $231, %eax
    xor %edi, %edi
    syscall

raise_usr1:
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $10, %edx
    syscall
    test %rax, %rax
    js fail
    ret

/* Whatever the call was, it was interrupted once by the handler, which saw the right masks. */
check:
    cmp $-4, %rax
    jne fail
    cmpq $1, seen(%rip)
    jne fail
    movq $0, seen(%rip)
    mov got_mask(%rip), %rax
    cmp mask_usr2_and_usr1(%rip), %rax
    jne fail
    mov got_frame_mask(%rip), %rax
    cmp mask_usr1(%rip), %rax
    jne fail
    /* the program's mask is back on the kernel's side */
    mov $14, %eax
    xor %edi, %edi
    xor %esi, %esi
    lea now_mask(%rip), %rdx
    mov $8, %r10d
    syscall
    mov now_mask(%rip), %rax
    cmp mask_usr1(%rip), %rax
    jne fail
    /* so a new SIGUSR1 stays queued */
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $10, %edx
    syscall
    mov $50, %ecx
1:  dec %ecx
    jnz 1b
    cmpq $0, seen(%rip)
    jne fail
    /* take it back off the queue, so the next round starts clean */
    mov $128, %eax
    lea mask_usr1(%rip), %rdi
    xor %esi, %esi
    lea no_wait(%rip), %rdx
    mov $8, %r10d
    syscall
    cmp $10, %rax
    jne fail
    ret

/* uc_sigmask is at 296 in the ucontext */
usr1_handler:
    incq seen(%rip)
    mov 296(%rdx), %rax
    mov %rax, got_frame_mask(%rip)
    mov $14, %eax
    xor %edi, %edi
    xor %esi, %esi
    lea got_mask(%rip), %rdx
    mov $8, %r10d
    syscall
    ret
alarm_handler:
    incq alarm_count(%rip)
    ret
restorer:
    mov $15, %eax
    syscall
fail:
    mov $1, %eax
    mov $1, %edi
    lea bad(%rip), %rsi
    mov $bad_end-bad, %edx
    syscall
    mov $231, %eax
    mov $1, %edi
    syscall

.data
.align 8
usr1_action:
    .quad usr1_handler, 0x04000004, restorer, 0
alarm_action:
    .quad alarm_handler, 0x04000004, restorer, 0
mask_usr1:
    .quad 1 << 9
mask_usr2:
    .quad 1 << 11
mask_usr2_and_usr1:
    .quad (1 << 9) | (1 << 11)
mask_alarm:
    .quad (1 << 9) | (1 << 13)
alarm_timer:
    .quad 0, 0, 0, 20000
short_wait:
    .quad 0, 200000000
timeout:
    .quad 5, 0
no_wait:
    .quad 0, 0
pselect_arg:
    .quad mask_usr2, 8
epev:
    .long 1
    .quad 0
epout:
    .space 16
pollfd:
    .space 8
fds:
    .long 0, 0
readset:
    .space 128
epfd:
    .quad 0
pid:
    .quad 0
tid:
    .quad 0
seen:
    .quad 0
alarm_count:
    .quad 0
got_mask:
    .quad 0
got_frame_mask:
    .quad 0
now_mask:
    .quad 0
good:
    .ascii "signal-tempmask-ok\n"
good_end:
bad:
    .ascii "signal-tempmask-FAILED\n"
bad_end:
