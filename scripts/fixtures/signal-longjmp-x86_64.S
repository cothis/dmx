/* A handler that never returns: it restores the mask and jumps out, as siglongjmp does. 200000 times each on
 * the normal stack and on an alternate one, also for a signal that arrives in a system call, as raise() is, and for
 * two handlers nested on the alternate stack, then on a second thread, whose host stack is much smaller than the first
 * thread's. Linux x86-64 ABI. */
.global _start
.text
_start:
    mov $131, %eax
    lea altdesc(%rip), %rdi
    xor %esi, %esi
    syscall
    test %rax, %rax
    js fail
    mov $13, %eax
    mov $11, %edi
    lea plain_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov %rsp, %r15
    mov $200000, %r12d
    call rounds
    mov $13, %eax
    mov $11, %edi
    lea alt_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $200000, %r12d
    call rounds
    /* raise() and jump out, on each stack */
    mov $39, %eax
    syscall
    mov %rax, pid(%rip)
    mov $186, %eax
    syscall
    mov %rax, tid(%rip)
    mov $13, %eax
    mov $10, %edi
    lea raise_plain_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $200000, %r12d
    call raise_rounds
    mov $13, %eax
    mov $10, %edi
    lea raise_alt_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $200000, %r12d
    call raise_rounds
    /* the same with a handler that makes no system call at all, as with _longjmp and SA_NODEFER */
    mov $13, %eax
    mov $10, %edi
    lea raise_bare_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $200000, %r12d
    call raise_rounds
    /* a fault the emulator itself raises, not the host: an invalid instruction, jumped out of */
    mov $13, %eax
    mov $4, %edi
    lea ud2_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $200000, %r12d
    call ud2_rounds
    /* two handlers nested on the alternate stack; the inner one jumps out */
    mov $13, %eax
    mov $10, %edi
    lea outer_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $13, %eax
    mov $12, %edi
    lea raise_alt_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $100000, %r12d
    call raise_rounds
    /* clone(CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM, stack) */
    mov $56, %eax
    mov $0x50f00, %edi
    lea thread_stack+65536(%rip), %rsi
    xor %edx, %edx
    xor %r10d, %r10d
    xor %r8d, %r8d
    syscall
    test %rax, %rax
    js fail
    jz second_thread
    mov $35, %eax
    lea long_wait(%rip), %rdi
    xor %esi, %esi
    syscall
    jmp fail
second_thread:
    mov $50000, %r12d
    call rounds
    mov $50000, %r12d
    call ud2_rounds
    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $18, %edx
    syscall
    mov $231, %eax
    xor %edi, %edi
    syscall
raise_rounds:
    mov %rsp, %r14
    mov %rsp, jmp_rsp(%rip)
1:
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $10, %edx
    syscall
    jmp fail
raised_back:
    cmp %r14, %rsp
    jne fail
    dec %r12d
    jnz 1b
    ret
raise_handler:
    mov $14, %eax
    mov $2, %edi
    lea empty(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov jmp_rsp(%rip), %rsp
    jmp raised_back
raise_bare_handler:
    mov jmp_rsp(%rip), %rsp
    jmp raised_back
ud2_rounds:
    mov %rsp, %r14
    mov %rsp, jmp_rsp(%rip)
1:
    ud2
    jmp fail
ud2_back:
    cmp %r14, %rsp
    jne fail
    dec %r12d
    jnz 1b
    ret
ud2_handler:
    mov $14, %eax
    mov $2, %edi
    lea empty(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov jmp_rsp(%rip), %rsp
    jmp ud2_back
outer_handler:
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $12, %edx
    syscall
    jmp fail
rounds:
    mov %rsp, %r14
    mov %rsp, jmp_rsp(%rip)
1:
    xor %eax, %eax
    mov (%rax), %rbx
    /* never reached: the handler jumps to back */
    jmp fail
back:
    cmp %r14, %rsp
    jne fail
    dec %r12d
    jnz 1b
    ret
handler:
    /* rt_sigprocmask(SIG_SETMASK, empty): what siglongjmp does with a saved mask */
    mov $14, %eax
    mov $2, %edi
    lea empty(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov jmp_rsp(%rip), %rsp
    jmp back
restorer:
    mov $15, %eax
    syscall
fail:
    mov $1, %eax
    mov $2, %edi
    lea bad(%rip), %rsi
    mov $19, %edx
    syscall
    mov $231, %eax
    mov $1, %edi
    syscall
.data
.align 8
raise_plain_action:
    .quad raise_handler, 0x04000004, restorer, 0
raise_alt_action:
    .quad raise_handler, 0x0C000004, restorer, 0
raise_bare_action:
    .quad raise_bare_handler, 0x44000004, restorer, 0
ud2_action:
    .quad ud2_handler, 0x04000004, restorer, 0
outer_action:
    .quad outer_handler, 0x0C000004, restorer, 0
pid:
    .quad 0
tid:
    .quad 0
plain_action:
    .quad handler, 0x04000004, restorer, 0
alt_action:
    .quad handler, 0x0C000004, restorer, 0
empty:
    .quad 0
long_wait:
    .quad 120, 0
jmp_rsp:
    .quad 0
altdesc:
    .quad altstack, 0, 65536
good:
    .ascii "signal-longjmp-ok\n"
bad:
    .ascii "signal-longjmp-bad\n"
.bss
.align 16
altstack:
    .space 65536
.align 16
thread_stack:
    .space 65536
