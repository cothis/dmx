/* A handler that moves the interrupted program, as Go's asynchronous preemption does: it pushes the
 * interrupted RIP on the interrupted stack and resumes at a routine that saves and restores every
 * register and then returns there. A real CPU only stops between instructions, so the program must
 * not notice. Linux x86-64 ABI. */
.global _start
.text
_start:
    mov $13, %eax
    mov $14, %edi
    lea action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
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
    mov %rsp, %r15
    movabs $0x1122334455667788, %rbx
    movabs $0x0123456789abcdef, %r12
    xor %r13d, %r13d
    xor %r14d, %r14d
    mov $300, %r11d
outer:
    mov $20000, %ecx
inner:
    push %rbx
    push %r12
    call callee
    pop %rax
    cmp %r12, %rax
    jne fail
    pop %rax
    cmp %rbx, %rax
    jne fail
    cmp %r15, %rsp
    jne fail
    mov $-1, %rax
    add $1, %rax
    adc $0, %r13
    lea 1(%r14), %r14
    xchg %rax, %rdx
    /* LOOP counts down in the instruction that branches, so rerunning it would count twice. */
    loop inner
    dec %r11d
    jnz outer
    mov $14, %eax
    xor %edi, %edi
    lea block_mask(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $6000000, %eax
    cmp %rax, %r13
    jne fail
    cmp %rax, %r14
    jne fail
    cmpq $10, moved(%rip)
    jb fail
    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $17, %edx
    syscall
    mov $60, %eax
    xor %edi, %edi
    syscall
callee:
    push %rbp
    mov %rsp, %rbp
    mov %rbx, %rax
    pop %rbp
    ret

/* uc_mcontext.gregs starts at 40; RSP is its 15th, RIP its 16th. */
handler:
    mov 160(%rdx), %rax
    sub $8, %rax
    mov 168(%rdx), %rcx
    mov %rcx, (%rax)
    mov %rax, 160(%rdx)
    lea preempt(%rip), %rcx
    mov %rcx, 168(%rdx)
    incq moved(%rip)
    ret
restorer:
    mov $15, %eax
    syscall

preempt:
    pushf
    push %rax
    push %rcx
    push %rdx
    push %rbx
    push %rbp
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15
    xor %eax, %eax
    xor %ecx, %ecx
    xor %edx, %edx
    xor %ebx, %ebx
    xor %ebp, %ebp
    xor %r11d, %r11d
    xor %r12d, %r12d
    xor %r13d, %r13d
    xor %r14d, %r14d
    xor %r15d, %r15d
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rdi
    pop %rsi
    pop %rbp
    pop %rbx
    pop %rdx
    pop %rcx
    pop %rax
    popf
    ret

fail:
    mov $14, %eax
    xor %edi, %edi
    lea block_mask(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $1, %eax
    mov $2, %edi
    lea bad(%rip), %rsi
    mov $21, %edx
    syscall
    mov $60, %eax
    mov $1, %edi
    syscall
.data
.align 8
moved:
    .quad 0
block_mask:
    .quad 8192
action:
    .quad handler, 0x14000004, restorer, 0
timer:
    .quad 0, 200, 0, 200
good:
    .ascii "signal-resume-ok\n"
bad:
    .ascii "signal-resume-broken\n"
