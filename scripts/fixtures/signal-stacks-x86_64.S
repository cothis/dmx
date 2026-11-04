/* Handlers that do what a real runtime does with stacks and system calls, none of which ends a frame.
 * 1: on an alternate stack, the handler moves to the interrupted stack, as .NET's does, makes a system
 *    call there, moves back and returns. The interrupted registers must come back whole.
 * 2: a handler jumps out without returning, and the next system call is a blocking one, interrupted by a signal
 *    whose handler makes a system call and returns. The call must go on being interrupted correctly.
 * 3: rt_sigsuspend with a mask allowing one signal: afterwards the program's own mask is back, on the
 *    kernel's side too, so a signal it does not block arrives, and one it blocks does not.
 * 4: a handler moves to a stack above the one it interrupted, makes a system call there, moves back and returns.
 *    Nothing tells that from having left the frame, so its return must work anyway.
 * 5: faults whose handlers jump out, so frames pile up past what can be live, each followed by a fault whose handler
 *    moves to a higher stack, makes a system call, moves back and returns past the fault. The first kind must not
 *    exhaust anything, and the second must come back whole when the pile gets released.
 * 6: a signal arriving in a system call, whose handler moves RIP elsewhere and returns, many more times than the
 *    host stack could hold what the call left on it.
 * 7: a fault whose handler changes only a register and returns, so the instruction runs again and now succeeds.
 *    Linux x86-64 ABI. */
.global _start
.text
_start:
    mov $39, %eax
    syscall
    mov %rax, pid(%rip)
    mov $186, %eax
    syscall
    mov %rax, tid(%rip)
    mov $131, %eax
    lea altdesc(%rip), %rdi
    xor %esi, %esi
    syscall
    test %rax, %rax
    js fail

    /* 1 */
    mov $13, %eax
    mov $10, %edi
    lea switch_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    movabs $0x1122334455667788, %rbx
    movabs $0x0123456789abcdef, %r12
    mov $20000, %r13d
one:
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $10, %edx
    syscall
    mov $50, %ecx
1:  dec %ecx
    jnz 1b
    movabs $0x1122334455667788, %rax
    cmp %rax, %rbx
    jne fail
    movabs $0x0123456789abcdef, %rax
    cmp %rax, %r12
    jne fail
    dec %r13d
    jnz one
    cmpq $20000, switched(%rip)
    jne fail

    /* 2 */
    mov $13, %eax
    mov $14, %edi
    lea alarm_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $13, %eax
    mov $11, %edi
    lea jump_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $22, %eax
    lea fds(%rip), %rdi
    syscall
    test %rax, %rax
    js fail
    mov $38, %eax
    xor %edi, %edi
    lea timer(%rip), %rsi
    xor %edx, %edx
    syscall
    test %rax, %rax
    js fail
    mov %rsp, jmp_rsp(%rip)
    mov $3000, %r13d
two:
    xor %eax, %eax
    mov (%rax), %rbx
    jmp fail
jumped:
    xor %eax, %eax
    mov fds(%rip), %edi
    lea buf(%rip), %rsi
    mov $1, %edx
    syscall
    cmp $-4, %rax
    jne fail
    cmp jmp_rsp(%rip), %rsp
    jne fail
    dec %r13d
    jnz two
    mov $38, %eax
    xor %edi, %edi
    lea no_timer(%rip), %rsi
    xor %edx, %edx
    syscall

    /* 3: SIGUSR2 blocked and SIGTERM not; suspend with only SIGUSR1 allowed */
    mov $13, %eax
    mov $12, %edi
    lea count_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $13, %eax
    mov $15, %edi
    lea count_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $13, %eax
    mov $10, %edi
    lea plain_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $14, %eax
    mov $2, %edi
    lea mask_usr2(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    /* a timer-free wake: a child sends SIGUSR1 in a moment */
    mov $57, %eax
    syscall
    test %rax, %rax
    js fail
    jnz suspend
    mov $35, %eax
    lea short_wait(%rip), %rdi
    xor %esi, %esi
    syscall
    mov $62, %eax
    mov pid(%rip), %rdi
    mov $10, %esi
    syscall
    mov $60, %eax
    xor %edi, %edi
    syscall
suspend:
    mov $130, %eax
    lea all_but_usr1(%rip), %rdi
    mov $8, %esi
    syscall
    cmp $-4, %rax
    jne fail
    cmpq $1, plain_count(%rip)
    jne fail
    /* the program's mask is back */
    mov $14, %eax
    xor %edi, %edi
    xor %esi, %esi
    lea got_mask(%rip), %rdx
    mov $8, %r10d
    syscall
    cmpq $0x800, got_mask(%rip)
    jne fail
    /* SIGTERM, which it does not block, arrives at once, and SIGUSR2 waits */
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $15, %edx
    syscall
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $12, %edx
    syscall
    mov $2000, %ecx
1:  dec %ecx
    jnz 1b
    cmpq $1, counted(%rip)
    jne fail
    mov $127, %eax
    lea got_pending(%rip), %rdi
    mov $8, %esi
    syscall
    testq $0x800, got_pending(%rip)
    jz fail

    /* 4: run on a low stack, with the process's own stack above it */
    mov $13, %eax
    mov $10, %edi
    lea high_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov %rsp, high_rsp(%rip)
    lea low_stack+65536(%rip), %rsp
    movabs $0x1122334455667788, %rbx
    movabs $0x0123456789abcdef, %r12
    mov $5000, %r13d
four:
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $10, %edx
    syscall
    mov $50, %ecx
1:  dec %ecx
    jnz 1b
    movabs $0x1122334455667788, %rax
    cmp %rax, %rbx
    jne fail
    movabs $0x0123456789abcdef, %rax
    cmp %rax, %r12
    jne fail
    dec %r13d
    jnz four
    cmpq $5000, high_seen(%rip)
    jne fail

    /* 5 */
    mov $13, %eax
    mov $11, %edi
    lea five_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov %rsp, jmp_rsp(%rip)
    movabs $0x1122334455667788, %r15
    mov $5000, %r13d
five:
    movq $0, five_returns(%rip)
    xor %eax, %eax
    mov (%rax), %rbx
    jmp fail
five_left:
    movabs $0x1122334455667788, %rbx
    movq $1, five_returns(%rip)
    xor %eax, %eax
    mov (%rax), %r15
    movabs $0x1122334455667788, %rax
    cmp %rax, %r15
    jne fail
    cmp %rax, %rbx
    jne fail
    movabs $0x0123456789abcdef, %rax
    cmp %rax, %r12
    jne fail
    dec %r13d
    jnz five

    /* 6 */
    mov $13, %eax
    mov $10, %edi
    lea six_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $200000, %r13d
six:
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $10, %edx
    syscall
    jmp fail
six_next:
    dec %r13d
    jnz six

    /* 7 */
    mov $13, %eax
    mov $11, %edi
    lea seven_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $5000, %r13d
seven:
    xor %eax, %eax
    xor %ebx, %ebx
    mov (%rax), %rbx
    movabs $0x1122334455667788, %rax
    cmp %rax, %rbx
    jne fail
    dec %r13d
    jnz seven

    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $17, %edx
    syscall
    mov $231, %eax
    xor %edi, %edi
    syscall

/* uc_mcontext.gregs starts at 40; RSP is its 15th. Moves to below the interrupted stack, keeping its red zone. */
switch_handler:
    mov 160(%rdx), %rax
    lea -256(%rax), %rax
    and $-16, %rax
    mov %rsp, %r14
    mov %rax, %rsp
    incq switched(%rip)
    /* rt_sigprocmask(SIG_UNBLOCK, a signal not blocked): a system call that changes nothing */
    mov $14, %eax
    mov $1, %edi
    lea mask_usr2(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $39, %eax
    syscall
    mov %r14, %rsp
    ret
high_handler:
    mov %rsp, %r14
    mov high_rsp(%rip), %rsp
    incq high_seen(%rip)
    mov $39, %eax
    syscall
    mov %r14, %rsp
    ret
five_handler:
    cmpq $0, five_returns(%rip)
    jne 1f
    mov $14, %eax
    mov $2, %edi
    lea empty(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov jmp_rsp(%rip), %rsp
    jmp five_left
1:  mov %rsp, %r14
    mov high_rsp(%rip), %rsp
    mov $39, %eax
    syscall
    mov %r14, %rsp
    /* past the three bytes of the faulting load: uc_mcontext RIP */
    addq $3, 168(%rdx)
    ret
six_handler:
    lea six_next(%rip), %rax
    mov %rax, 168(%rdx)
    ret
/* uc_mcontext RAX: gregs starts at 40, RAX is its 14th */
seven_handler:
    lea seven_value(%rip), %rax
    mov %rax, 144(%rdx)
    ret
alarm_handler:
    mov $39, %eax
    syscall
    ret
jump_handler:
    mov $14, %eax
    mov $2, %edi
    lea empty(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov jmp_rsp(%rip), %rsp
    jmp jumped
count_handler:
    incq counted(%rip)
    ret
plain_handler:
    incq plain_count(%rip)
    ret
restorer:
    mov $15, %eax
    syscall
fail:
    mov $1, %eax
    mov $2, %edi
    lea bad(%rip), %rsi
    mov $18, %edx
    syscall
    mov $231, %eax
    mov $1, %edi
    syscall
.data
.align 8
/* SA_ONSTACK */
switch_action:
    .quad switch_handler, 0x1C000004, restorer, 0
five_action:
    .quad five_handler, 0x04000004, restorer, 0
six_action:
    .quad six_handler, 0x04000004, restorer, 0
seven_action:
    .quad seven_handler, 0x04000004, restorer, 0
seven_value:
    .quad 0x1122334455667788
high_action:
    .quad high_handler, 0x14000004, restorer, 0
alarm_action:
    .quad alarm_handler, 0x04000004, restorer, 0
jump_action:
    .quad jump_handler, 0x04000004, restorer, 0
count_action:
    .quad count_handler, 0x14000004, restorer, 0
plain_action:
    .quad plain_handler, 0x14000004, restorer, 0
altdesc:
    .quad altstack, 0, 65536
timer:
    .quad 0, 300, 0, 300
no_timer:
    .quad 0, 0, 0, 0
short_wait:
    .quad 0, 200000000
fds:
    .quad 0
buf:
    .quad 0
empty:
    .quad 0
mask_usr2:
    .quad 0x800
all_but_usr1:
    .quad 0xfffffffffffffdff
jmp_rsp:
    .quad 0
high_rsp:
    .quad 0
high_seen:
    .quad 0
five_returns:
    .quad 0
pid:
    .quad 0
tid:
    .quad 0
switched:
    .quad 0
counted:
    .quad 0
plain_count:
    .quad 0
got_mask:
    .quad 0
got_pending:
    .quad 0
good:
    .ascii "signal-stacks-ok\n"
bad:
    .ascii "signal-stacks-bad\n"
.bss
.align 16
altstack:
    .space 65536
.align 16
low_stack:
    .space 65536
