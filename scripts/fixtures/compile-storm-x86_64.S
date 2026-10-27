/* A benchmark, not a regression: no test runs it. A JIT-like compile storm
 * writes 262144 16-byte functions (mov $i, %eax; ret) into 4 MiB of RWX
 * memory, then calls each once, so every call translates a new block on an
 * already-written page. Prints the call phase in nanoseconds, in hex. */
.global _start
.text
_start:
    mov $9, %eax
    xor %edi, %edi
    mov $4194304, %esi
    mov $7, %edx
    mov $0x22, %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    test %rax, %rax
    js fail
    mov %rax, %r13
    xor %ecx, %ecx
fill:
    mov %rcx, %rax
    shl $8, %rax
    movabs $0x9090c300000000b8, %rdx
    or %rdx, %rax
    mov %rcx, %rdx
    shl $4, %rdx
    mov %rax, (%r13,%rdx)
    movq $0, 8(%r13,%rdx)
    inc %ecx
    cmp $262144, %ecx
    jb fill
    lea t0(%rip), %rsi
    call now
    xor %r12d, %r12d
    xor %r14d, %r14d
run:
    mov %r12, %rax
    shl $4, %rax
    add %r13, %rax
    call *%rax
    cmp %r12d, %eax
    jne fail
    inc %r12
    cmp $262144, %r12
    jb run
    lea t1(%rip), %rsi
    call now
    mov t1(%rip), %rax
    sub t0(%rip), %rax
    imul $1000000000, %rax
    add t1+8(%rip), %rax
    sub t0+8(%rip), %rax
    mov %rax, %rbx
    lea hex+16(%rip), %rsi
    mov $16, %ecx
1:  mov %ebx, %edx
    and $15, %edx
    lea digits(%rip), %r8
    movb (%r8,%rdx), %dl
    dec %rsi
    movb %dl, (%rsi)
    shr $4, %rbx
    dec %ecx
    jnz 1b
    mov $1, %eax
    mov $1, %edi
    mov $17, %edx
    syscall
    xor %edi, %edi
    jmp exit
now:                            /* clock_gettime(CLOCK_MONOTONIC, rsi) */
    mov $228, %eax
    mov $1, %edi
    syscall
    ret
fail:
    mov $2, %edi
exit:
    mov $231, %eax
    syscall
.data
.align 8
t0: .quad 0, 0
t1: .quad 0, 0
hex: .space 16
    .ascii "\n"
digits: .ascii "0123456789abcdef"
