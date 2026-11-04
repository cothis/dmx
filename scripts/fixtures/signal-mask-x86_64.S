/* Signals with faults and with a handler that abandons a blocking call, which must leave the mask and the
 * registers as a real kernel would. A periodic SIGALRM runs throughout, with an empty sa_mask.
 * Writes to a page of code that keeps being called come first: an emulator has to catch those itself,
 * also while a signal is held back.
 * First 5000 faults whose handler skips the instruction: a signal held back when a fault arrives must not
 * leave the fault's mask behind. Then blocking reads that the handler abandons by moving RIP past the
 * system call, as pthread_cancel does, each followed by code that checks its registers. Then the mask
 * must be empty. Linux x86-64 ABI. */
.global _start
.text
_start:
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
    lea segv_action(%rip), %rsi
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
    mov $9, %eax
    xor %edi, %edi
    mov $4096, %esi
    mov $7, %edx
    mov $0x22, %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    test %rax, %rax
    js fail
    mov %rax, %r15
    movb $0xc3, (%r15)
    mov $20000, %r12d
writes:
    call *%r15
    /* Straight-line code, so a signal is likely to be held back when the write comes. */
    .rept 400
    add $1, %rax
    .endr
    movb $0xc3, 8(%r15)
    mov $50, %ecx
spin0:
    dec %ecx
    jnz spin0
    dec %r12d
    jnz writes
    mov $5000, %r12d
faults:
    xor %eax, %eax
fault_at:
    mov (%rax), %rbx
after_fault:
    mov $2000, %ecx
spin1:
    dec %ecx
    jnz spin1
    dec %r12d
    jnz faults
    cmpq $5000, faults_seen(%rip)
    jne fail
    movabs $0x1122334455667788, %rbx
    movabs $0x0123456789abcdef, %r12
    mov $0x5a5a5a5a, %r13d
    mov $500, %r14d
cancels:
    movb $1, cancelling(%rip)
    xor %eax, %eax
    mov fds(%rip), %edi
    lea buf(%rip), %rsi
    mov $1, %edx
read_at:
    syscall
after_read:
    jmp fail
cancelled:
    movb $0, cancelling(%rip)
    mov $2000, %ecx
spin2:
    add $1, %r13
    sub $1, %r13
    dec %ecx
    jnz spin2
    movabs $0x1122334455667788, %rax
    cmp %rax, %rbx
    jne fail
    movabs $0x0123456789abcdef, %rax
    cmp %rax, %r12
    jne fail
    cmp $0x5a5a5a5a, %r13
    jne fail
    dec %r14d
    jnz cancels
    /* Reads the mask back: SIG_BLOCK with no set. */
    mov $14, %eax
    xor %edi, %edi
    xor %esi, %esi
    lea oldmask(%rip), %rdx
    mov $8, %r10d
    syscall
    test %rax, %rax
    jnz fail
    cmpq $0, oldmask(%rip)
    jne fail
    cmpq $100, alarms(%rip)
    jb fail
    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $15, %edx
    syscall
    mov $60, %eax
    xor %edi, %edi
    syscall

/* uc_mcontext.gregs starts at 40; RIP is its 16th. */
segv_handler:
    lea after_fault(%rip), %rax
    mov %rax, 168(%rdx)
    incq faults_seen(%rip)
    ret
alarm_handler:
    incq alarms(%rip)
    cmpb $0, cancelling(%rip)
    je 1f
    mov 168(%rdx), %rax
    lea read_at(%rip), %rcx
    cmp %rcx, %rax
    je 2f
    lea after_read(%rip), %rcx
    cmp %rcx, %rax
    jne 1f
2:
    lea cancelled(%rip), %rax
    mov %rax, 168(%rdx)
1:
    ret
restorer:
    mov $15, %eax
    syscall
fail:
    mov $1, %eax
    mov $2, %edi
    lea bad(%rip), %rsi
    mov $16, %edx
    syscall
    mov $60, %eax
    mov $1, %edi
    syscall
.data
.align 8
alarm_action:
    .quad alarm_handler, 0x04000004, restorer, 0
segv_action:
    .quad segv_handler, 0x04000004, restorer, 0
timer:
    .quad 0, 200, 0, 200
fds:
    .quad 0
buf:
    .quad 0
oldmask:
    .quad -1
alarms:
    .quad 0
faults_seen:
    .quad 0
cancelling:
    .quad 0
good:
    .ascii "signal-mask-ok\n"
bad:
    .ascii "signal-mask-bad\n"
