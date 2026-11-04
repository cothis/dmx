/* A blocking system call right after ordinary code, with a periodic signal and no SA_RESTART: each
 * read of an empty pipe must end with EINTR at the next signal. If an emulator held a signal back
 * with the signal masked and then entered the call, the read would sleep forever. Then with SA_RESTART:
 * one read, which a child ends after 100 ms, must take every signal that arrives while it blocks, not
 * only the first. The timer stays armed through the exit, which no handler may interrupt. Linux x86-64 ABI. */
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
    mov $3000, %r12d
loop:
    mov %r12d, %ecx
    and $255, %ecx
    add $1, %ecx
spin:
    dec %ecx
    jnz spin
    xor %eax, %eax
    mov fds(%rip), %edi
    lea buf(%rip), %rsi
    mov $1, %edx
    syscall
    cmp $-4, %rax
    jne fail
    dec %r12d
    jnz loop
    mov $13, %eax
    mov $14, %edi
    lea action_restart(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $57, %eax
    syscall
    test %rax, %rax
    js fail
    jnz parent
    mov $35, %eax
    lea delay(%rip), %rdi
    xor %esi, %esi
    syscall
    mov $1, %eax
    mov fds+4(%rip), %edi
    lea buf(%rip), %rsi
    mov $1, %edx
    syscall
    mov $60, %eax
    xor %edi, %edi
    syscall
parent:
    movq $0, signals(%rip)
    xor %eax, %eax
    mov fds(%rip), %edi
    lea buf(%rip), %rsi
    mov $1, %edx
    syscall
    cmp $1, %rax
    jne fail
    cmpq $20, signals(%rip)
    jb fail
    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $18, %edx
    syscall
    mov $60, %eax
    xor %edi, %edi
    syscall
handler:
    incq signals(%rip)
    ret
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
action:
    .quad handler, 0x04000004, restorer, 0
action_restart:
    .quad handler, 0x14000004, restorer, 0
delay:
    .quad 0, 100000000
signals:
    .quad 0
timer:
    .quad 0, 100, 0, 100
fds:
    .quad 0
buf:
    .quad 0
good:
    .ascii "signal-syscall-ok\n"
bad:
    .ascii "signal-syscall-bad\n"
