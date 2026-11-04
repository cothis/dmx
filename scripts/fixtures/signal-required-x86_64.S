/* Signals FEX cannot leave blocked on the host, sent to the program while it blocks them. They must arrive when the
 * mask lets them in, as any other would: when a sigreturn changes the mask, with no system call after it, and when a
 * call's own mask does, which must wake that call. And a mask at a bad address is an error, not a crash. Linux x86-64 ABI. */
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
    mov $11, %edi
    lea segv_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    mov $13, %eax
    mov $10, %edi
    lea usr1_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail

    /* a sigreturn lets it in */
    mov $2000, %r13d
one:
    call block_segv
    call raise_segv
    mov $200, %ecx
1:  dec %ecx
    jnz 1b
    cmpq $0, count(%rip)
    jne fail
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $10, %edx
    syscall
    /* no system call from here on until it has come */
    mov $200000000, %ecx
2:  cmpq $1, count(%rip)
    je 3f
    dec %ecx
    jnz 2b
    jmp fail
3:  movq $0, count(%rip)
    dec %r13d
    jnz one

    /* a call's mask lets it in, and it wakes the call */
    mov $2000, %r13d
two:
    call block_segv
    call raise_segv
    /* ppoll(0, 0, timeout, empty, 8) */
    mov $271, %eax
    xor %edi, %edi
    xor %esi, %esi
    lea long_wait(%rip), %rdx
    lea empty(%rip), %r10
    mov $8, %r8d
    syscall
    cmp $-4, %rax
    jne fail
    cmpq $1, count(%rip)
    jne fail
    movq $0, count(%rip)
    dec %r13d
    jnz two

    /* rt_sigsuspend's own bad arguments */
    mov $130, %eax
    mov $8, %edi
    mov $8, %esi
    syscall
    cmp $-14, %rax
    jne fail
    mov $130, %eax
    lea empty(%rip), %rdi
    mov $4, %esi
    syscall
    cmp $-22, %rax
    jne fail

    /* bad masks */
    mov $271, %eax
    xor %edi, %edi
    xor %esi, %esi
    lea short_wait(%rip), %rdx
    mov $8, %r10d
    mov $8, %r8d
    syscall
    cmp $-14, %rax
    jne fail
    /* pselect6(0, 0, 0, 0, timeout, bad arguments) */
    mov $270, %eax
    xor %edi, %edi
    xor %esi, %esi
    xor %edx, %edx
    xor %r10d, %r10d
    lea short_wait(%rip), %r8
    mov $8, %r9d
    syscall
    cmp $-14, %rax
    jne fail
    /* the same with good arguments holding a bad mask */
    mov $270, %eax
    xor %edi, %edi
    xor %esi, %esi
    xor %edx, %edx
    xor %r10d, %r10d
    lea short_wait(%rip), %r8
    lea bad_mask_args(%rip), %r9
    syscall
    cmp $-14, %rax
    jne fail

    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $good_end-good, %edx
    syscall
    mov $231, %eax
    xor %edi, %edi
    syscall

block_segv:
    mov $14, %eax
    xor %edi, %edi
    lea mask_segv(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail
    ret
raise_segv:
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $11, %edx
    syscall
    test %rax, %rax
    js fail
    ret

segv_handler:
    incq count(%rip)
    ret
/* uc_sigmask is at 296 in the ucontext: return with nothing blocked */
usr1_handler:
    movq $0, 296(%rdx)
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
segv_action:
    .quad segv_handler, 0x04000004, restorer, 0
usr1_action:
    .quad usr1_handler, 0x04000004, restorer, 0
mask_segv:
    .quad 1 << 10
empty:
    .quad 0
long_wait:
    .quad 20, 0
short_wait:
    .quad 0, 1000000
bad_mask_args:
    .quad 8, 8
pid:
    .quad 0
tid:
    .quad 0
count:
    .quad 0
good:
    .ascii "signal-required-ok\n"
good_end:
bad:
    .ascii "signal-required-FAILED\n"
bad_end:
