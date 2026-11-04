/* Code rewritten through a second mapping of the same memory, which is how .NET's W^X works: the code runs from a
 * read-execute view of a memfd, and to change it the runtime maps a read-write view, writes and unmaps it.
 * Nothing is written through the view that runs, and the view that is written did not exist when the code was
 * translated. The new code must run regardless, each time.
 * 1: a new read-write view for every change. 2: a view mapped read-only, then made writable with mprotect.
 * 3: one view kept, written many times.
 * First a system call fills a new view of this memory before any of it has run, as a loader does. Linux x86-64 ABI. */
.global _start
.text
_start:
    /* memfd_create("code", 0), one page */
    mov $319, %eax
    lea name(%rip), %rdi
    xor %esi, %esi
    syscall
    test %rax, %rax
    js fail
    mov %rax, %r12
    mov $77, %eax
    mov %r12, %rdi
    mov $4096, %esi
    syscall
    test %rax, %rax
    js fail

    /* a read-execute view first, then the first code through a pipe into a view that is gone before it runs */
    mov $5, %edx
    call map_view
    mov %rax, %r13
    mov $22, %eax
    lea fds(%rip), %rdi
    syscall
    test %rax, %rax
    js fail
    mov $1, %eax
    mov fds+4(%rip), %edi
    lea code(%rip), %rsi
    mov $code_end-code, %edx
    syscall
    cmp $code_end-code, %rax
    jne fail
    mov $3, %edx
    call map_view
    mov %rax, %r14
    xor %eax, %eax
    mov fds(%rip), %edi
    mov %r14, %rsi
    mov $code_end-code, %edx
    syscall
    cmp $code_end-code, %rax
    jne fail
    mov %r14, %rdi
    mov $11, %eax
    mov $4096, %esi
    syscall

    call *%r13
    cmp $1, %eax
    jne fail

    /* 1 */
    mov $2000, %r14d
one:
    mov $3, %edx
    call map_view
    mov %r14d, 1(%rax)
    mov %rax, %rdi
    mov $11, %eax
    mov $4096, %esi
    syscall
    call *%r13
    cmp %r14d, %eax
    jne fail
    dec %r14d
    jnz one

    /* 2 */
    mov $2000, %r14d
two:
    mov $1, %edx
    call map_view
    mov %rax, %r15
    mov $10, %eax
    mov %r15, %rdi
    mov $4096, %esi
    mov $3, %edx
    syscall
    test %rax, %rax
    jnz fail
    mov %r14d, 1(%r15)
    mov $11, %eax
    mov %r15, %rdi
    mov $4096, %esi
    syscall
    call *%r13
    cmp %r14d, %eax
    jne fail
    dec %r14d
    jnz two

    /* 3 */
    mov $3, %edx
    call map_view
    mov %rax, %r15
    mov $2000, %r14d
three:
    mov %r14d, 1(%r15)
    call *%r13
    cmp %r14d, %eax
    jne fail
    dec %r14d
    jnz three

    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $good_end-good, %edx
    syscall
    mov $231, %eax
    xor %edi, %edi
    syscall

/* mmap(0, 4096, prot in edx, MAP_SHARED, memfd, 0) */
map_view:
    mov $9, %eax
    xor %edi, %edi
    mov $4096, %esi
    mov $1, %r10d
    mov %r12, %r8
    xor %r9d, %r9d
    syscall
    cmp $-4096, %rax
    ja fail
    ret

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
fds:
    .long 0, 0
name:
    .asciz "code"
/* mov $1, %eax; ret */
code:
    .byte 0xb8
    .long 1
    .byte 0xc3
code_end:
good:
    .ascii "code-alias-ok\n"
good_end:
bad:
    .ascii "code-alias-FAILED\n"
bad_end:
