/* A code-patching regression: one thread keeps replacing an aligned eight-byte
 * code word, as HotSpot patches a method entry, while another calls it. Both
 * versions are one five-byte instruction followed by ret and return 42:
 *   b8 2a 00 00 00 c3 90 90   mov $42, %eax
 *   e9 3b 00 00 00 c3 90 90   jmp entry+64 (mov $42, %eax; ret)
 * A decoder that reads the opcode and the operand at different times mixes
 * them: b8 with 3b returns 59, e9 with 2a runs zero bytes and returns the
 * scratch address. Exits 3 with the value on a mix, 4 if the writer stalled. */
.global _start
.text
_start:
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
    movabs $0x9090c30000003be9, %r14
    movabs $0x9090c30000002ab8, %r15
    mov %r15, (%r13)
    mov %r15, 64(%r13)
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

wait_writer:
    cmpq $0, flips(%rip)
    je wait_writer
    mov flips(%rip), %rbx
    xor %r12d, %r12d
reader:
    lea scratch(%rip), %rax
    call *%r13
    cmp $42, %eax
    jne mixed
    add $1, %r12
    cmp $200000, %r12
    jb reader
    /* Keep calling until the writer has replaced the word a million times. */
    mov flips(%rip), %rax
    sub %rbx, %rax
    cmp $1000000, %rax
    jae done
    cmp $100000000, %r12
    jb reader
    movl $1, reader_done(%rip)
    lea stalled(%rip), %rsi
    mov $(stalled_end-stalled), %edx
    call print
    mov $4, %edi
    jmp exit
done:
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
    mov %r14, (%r13)
    mov %r15, (%r13)
    addq $1, flips(%rip)
    cmpl $0, reader_done(%rip)
    je writer
    movl $1, writer_exited(%rip)
    mov $60, %eax
    xor %edi, %edi
    syscall

mixed:
    mov %rax, %rbx
    movl $1, reader_done(%rip)
    lea bad(%rip), %rsi
    mov $(bad_end-bad), %edx
    call print
    lea hex+16(%rip), %rsi
    mov $16, %ecx
digit:
    mov %ebx, %edx
    and $15, %edx
    lea digits(%rip), %r8
    movb (%r8,%rdx), %dl
    dec %rsi
    movb %dl, (%rsi)
    shr $4, %rbx
    dec %ecx
    jnz digit
    mov $17, %edx
    call print
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

.data
.align 8
flips: .quad 0
reader_done: .long 0
writer_exited: .long 0
.align 64
scratch: .space 128
hex: .space 16
    .ascii "\n"
digits: .ascii "0123456789abcdef"
good: .ascii "entry-patch-ok\n"
good_end:
bad: .ascii "entry-patch-mixed eax=0x"
bad_end:
stalled: .ascii "entry-patch-writer-stalled\n"
stalled_end:
