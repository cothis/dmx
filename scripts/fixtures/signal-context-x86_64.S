/* What a handler can do with the context and the mask, as a kernel lets it.
 * 1: a handler sees the interrupted mask in uc_sigmask, and what it writes there is the mask after it returns.
 *    musl's pthread_cancel relies on this: without it a busy thread takes the same signal forever.
 * 2: a signal the program blocks stays queued in the kernel during another signal's handler, with its payload,
 *    so that sigsuspend can still take it and rt_sigtimedwait can read the value.
 * 3: thirty realtime signals of one number queued to this thread arrive in order. Linux x86-64 ABI. */
.global _start
.text
_start:
    /* 1. SIGUSR1's handler blocks SIGUSR1 through its context and raises it again. */
    mov $13, %eax
    mov $10, %edi
    lea usr1_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    movq $0x4000, mask_sigterm(%rip)
    /* A mask in place, so the handler has something to see: SIGTERM blocked. */
    mov $14, %eax
    mov $2, %edi
    lea mask_sigterm(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $39, %eax
    syscall
    mov %rax, pid(%rip)
    mov $186, %eax
    syscall
    mov %rax, tid(%rip)
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $10, %edx
    syscall
    mov $2000, %ecx
1:  dec %ecx
    jnz 1b
    /* It ran once, saw SIGTERM blocked, and SIGUSR1 is now blocked and pending. */
    cmpq $1, usr1_count(%rip)
    jne fail
    cmpq $0x4000, usr1_seen(%rip)
    jne fail
    mov $14, %eax
    xor %edi, %edi
    xor %esi, %esi
    lea got_mask(%rip), %rdx
    mov $8, %r10d
    syscall
    cmpq $0x4200, got_mask(%rip)
    jne fail
    mov $127, %eax
    lea got_pending(%rip), %rdi
    mov $8, %esi
    syscall
    testq $0x200, got_pending(%rip)
    jz fail
    /* Set the handler to do nothing more, then let it through. */
    movq $1, usr1_done(%rip)
    mov $14, %eax
    mov $2, %edi
    lea mask_sigterm(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    cmpq $2, usr1_count(%rip)
    jne fail

    /* 2. SIGUSR2 blocked by the program, queued with a value from inside SIGALRM's handler. */
    mov $13, %eax
    mov $14, %edi
    lea alarm_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $14, %eax
    mov $2, %edi
    lea mask_usr2(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $14, %edx
    syscall
    mov $2000, %ecx
1:  dec %ecx
    jnz 1b
    cmpq $1, alarm_count(%rip)
    jne fail
    mov $127, %eax
    lea got_pending(%rip), %rdi
    mov $8, %esi
    syscall
    testq $0x800, got_pending(%rip)
    jz fail
    /* rt_sigtimedwait reads it, with the value, without a handler. */
    mov $128, %eax
    lea only_usr2(%rip), %rdi
    lea info(%rip), %rsi
    lea no_time(%rip), %rdx
    mov $8, %r10d
    syscall
    cmp $12, %rax
    jne fail
    cmpl $-1, info+8(%rip)
    jne fail
    cmpq $77, info+24(%rip)
    jne fail

    /* 3. Realtime signal 40, blocked, queued three times, and let go during busy code. */
    mov $13, %eax
    mov $40, %edi
    lea rt_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $200, %r12d
rounds:
    movq $0, rt_seen(%rip)
    movq $0, rt_bad(%rip)
    mov $14, %eax
    xor %edi, %edi
    lea mask_rt(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $1, %r13d
queue:
    mov %r13, queue_info+24(%rip)
    mov $297, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $40, %edx
    lea queue_info(%rip), %r10
    syscall
    test %rax, %rax
    js fail
    inc %r13d
    cmp $31, %r13d
    jne queue
    mov $14, %eax
    mov $1, %edi
    lea mask_rt(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $5000, %ecx
1:  dec %ecx
    jnz 1b
    cmpq $30, rt_seen(%rip)
    jne fail
    cmpq $0, rt_bad(%rip)
    jne fail
    dec %r12d
    jnz rounds

    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $18, %edx
    syscall
    mov $60, %eax
    xor %edi, %edi
    syscall

/* uc_sigmask is at 296 in the ucontext. */
usr1_handler:
    incq usr1_count(%rip)
    cmpq $0, usr1_done(%rip)
    jne 1f
    mov 296(%rdx), %rax
    mov %rax, usr1_seen(%rip)
    orq $0x200, 296(%rdx)
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $10, %edx
    syscall
1:  ret
alarm_handler:
    incq alarm_count(%rip)
    mov $297, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $12, %edx
    lea usr2_info(%rip), %r10
    syscall
    mov $2000, %ecx
1:  dec %ecx
    jnz 1b
    ret
rt_handler:
    mov 24(%rsi), %rax
    incq rt_seen(%rip)
    cmp rt_seen(%rip), %rax
    je 1f
    movq $1, rt_bad(%rip)
1:  ret
restorer:
    mov $15, %eax
    syscall
fail:
    mov $1, %eax
    mov $2, %edi
    lea bad(%rip), %rsi
    mov $19, %edx
    syscall
    mov $60, %eax
    mov $1, %edi
    syscall
.data
.align 8
usr1_action:
    .quad usr1_handler, 0x04000004, restorer, 0
alarm_action:
    .quad alarm_handler, 0x04000004, restorer, 0
rt_action:
    .quad rt_handler, 0x04000004, restorer, 0
mask_sigterm:
    .quad 0x4000
mask_usr2:
    .quad 0x800
only_usr2:
    .quad 0x800
mask_rt:
    .quad 0x8000000000
no_time:
    .quad 0, 0
pid:
    .quad 0
tid:
    .quad 0
usr1_count:
    .quad 0
usr1_seen:
    .quad 0
usr1_done:
    .quad 0
alarm_count:
    .quad 0
got_mask:
    .quad 0
got_pending:
    .quad 0
rt_seen:
    .quad 0
rt_bad:
    .quad 0
/* si_signo, si_errno, si_code; pid and uid; value */
usr2_info:
    .long 12, 0, -1, 0
    .quad 0
    .quad 77
    .fill 96, 1, 0
queue_info:
    .long 40, 0, -1, 0
    .quad 0
    .quad 0
    .fill 96, 1, 0
info:
    .fill 128, 1, 0
good:
    .ascii "signal-context-ok\n"
bad:
    .ascii "signal-context-bad\n"
