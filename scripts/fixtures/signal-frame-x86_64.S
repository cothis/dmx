/* A signal-return regression: nested stack frames retain their data while a
 * periodic signal handler returns to the same instruction. Linux x86-64 ABI. */
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
    mov $300, %r12d
outer:
    mov $20000, %ecx
shallow:
    dec %ecx
    jnz shallow
    mov $12, %edi
    call deep
    dec %r12d
    jnz outer
    mov $14, %eax
    xor %edi, %edi
    lea block_mask(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    cmpq $10, signal_count(%rip)
    jb fail
    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $17, %edx
    syscall
    mov $60, %eax
    xor %edi, %edi
    syscall

deep:
    push %rbp
    mov %rsp, %rbp
    sub $1040, %rsp
    mov %edi, -8(%rbp)
    movabs $0x55aa33cc5a5a1234, %rax
    mov $128, %ecx
    lea -1040(%rbp), %rdx
fill:
    mov %rax, (%rdx)
    add $8, %rdx
    dec %ecx
    jnz fill
    test %edi, %edi
    jz busy
    dec %edi
    call deep
busy:
    mov $20000, %ecx
spin:
    dec %ecx
    jnz spin
    movabs $0x55aa33cc5a5a1234, %rax
    mov $128, %ecx
    lea -1040(%rbp), %rdx
check:
    cmp %rax, (%rdx)
    jne fail
    add $8, %rdx
    dec %ecx
    jnz check
    leave
    ret
handler:
    incq signal_count(%rip)
    ret
restorer:
    mov $15, %eax
    syscall
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
    mov $24, %edx
    syscall
    mov $60, %eax
    mov $1, %edi
    syscall
.data
.align 8
signal_count:
    .quad 0
block_mask:
    .quad 8192
action:
    .quad handler, 0x14000004, restorer, 0
timer:
    .quad 0, 100, 0, 100
good:
    .ascii "signal-frames-ok\n\0\0"
bad:
    .ascii "signal-frame-corruption\n\0"
