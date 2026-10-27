/* A stale-translation regression: one thread stores "mov $n, %eax; ret" into
 * an aligned code word, publishes n and spins argv[1] iterations; another
 * loads the published n, runs CPUID (serializing, as x86 cross-modifying code
 * requires) and calls the code, which must return at least n. Less means a
 * translation of older bytes still runs after the new bytes were published.
 * Exits 5 with both values on stale code, 3 on a value never published. */
.global _start
.text
_start:
    mov 16(%rsp), %rsi
    xor %eax, %eax
    test %rsi, %rsi
    jz parsed
parse:
    movzbl (%rsi), %ecx
    sub $48, %ecx
    cmp $9, %ecx
    ja parsed
    imul $10, %rax
    add %rcx, %rax
    inc %rsi
    jmp parse
parsed:
    mov %rax, spin(%rip)
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
    mov %rax, %r13
    movabs $0x9090c300000000b8, %r15
    mov %r15, (%r13)
    mov $9, %eax
    xor %edi, %edi
    mov $65536, %esi
    mov $3, %edx
    mov $0x22, %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    test %rax, %rax
    js fail
    mov $56, %eax
    mov $0x50f00, %edi
    lea 65536(%rax), %rsi
    xor %edx, %edx
    xor %r10d, %r10d
    xor %r8d, %r8d
    syscall
    test %rax, %rax
    js fail
    jz writer

    xor %r12d, %r12d
reader:
    mov published(%rip), %r14
    xor %eax, %eax
    cpuid
    call *%r13
    mov %eax, %eax
    /* Code n is stored before n is published, so n + 1 may already run. */
    mov published(%rip), %rdx
    inc %rdx
    cmp %rdx, %rax
    ja garbage
    cmp %r14, %rax
    jb stale
    add $1, %r12
    cmp $1000000, %r12
    jb reader
    movl $1, reader_done(%rip)
wait_exit:
    cmpl $1, writer_exited(%rip)
    jne wait_exit
    lea good(%rip), %rsi
    mov $(good_end-good), %edx
    call print
    xor %edi, %edi
    jmp exit

writer:
    mov $1, %ebx
next:
    mov %rbx, %rax
    shl $8, %rax
    or %r15, %rax
    mov %rax, (%r13)
    mov %rbx, published(%rip)
    mov spin(%rip), %rcx
    test %rcx, %rcx
    jz 2f
1:  dec %rcx
    jnz 1b
2:  inc %ebx
    cmpl $0, reader_done(%rip)
    je next
    movl $1, writer_exited(%rip)
    mov $60, %eax
    xor %edi, %edi
    syscall

stale:
    mov %rax, %rbx
    movl $1, reader_done(%rip)
    lea old(%rip), %rsi
    mov $(old_end-old), %edx
    call print
    call print_hex
    lea want(%rip), %rsi
    mov $(want_end-want), %edx
    call print
    mov %r14, %rbx
    call print_hex
    mov $5, %edi
    jmp exit
garbage:
    mov %rax, %rbx
    movl $1, reader_done(%rip)
    lea junk(%rip), %rsi
    mov $(junk_end-junk), %edx
    call print
    call print_hex
    mov $3, %edi
    jmp exit
fail:
    mov $2, %edi
exit:
    mov $231, %eax
    syscall
print:
    mov $1, %eax
    mov $1, %edi
    syscall
    ret
print_hex:
    lea hex+16(%rip), %rsi
    mov $16, %ecx
3:  mov %ebx, %edx
    and $15, %edx
    lea digits(%rip), %r8
    movb (%r8,%rdx), %dl
    dec %rsi
    movb %dl, (%rsi)
    shr $4, %rbx
    dec %ecx
    jnz 3b
    mov $17, %edx
    jmp print

.data
.align 8
published: .quad 0
spin: .quad 0
reader_done: .long 0
writer_exited: .long 0
hex: .space 16
    .ascii "\n"
digits: .ascii "0123456789abcdef"
good: .ascii "code-stale-ok\n"
good_end:
old: .ascii "code-stale-old got=0x"
old_end:
want: .ascii "want>=0x"
want_end:
junk: .ascii "code-stale-garbage got=0x"
junk_end:
