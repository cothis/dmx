/* A vfork child whose descendant shares its descriptors and outlives it: the parent goes on when the
 * child exits, as the kernel has it, not when the descendant does. Linux x86-64 ABI. */
.global _start
.text
_start:
    mov $58, %eax
    syscall
    test %rax, %rax
    js fail
    jnz parent
    /* clone(CLONE_FILES | SIGCHLD): sharing the descriptor table */
    mov $56, %eax
    mov $0x411, %edi
    xor %esi, %esi
    xor %edx, %edx
    xor %r10d, %r10d
    xor %r8d, %r8d
    syscall
    test %rax, %rax
    jnz child_exit
    /* the descendant lives on for 20 seconds */
    mov $35, %eax
    lea twenty(%rip), %rdi
    xor %esi, %esi
    syscall
child_exit:
    mov $60, %eax
    xor %edi, %edi
    syscall
parent:
    mov $60, %eax
    xor %edi, %edi
    syscall
fail:
    mov $60, %eax
    mov $1, %edi
    syscall
.data
.align 8
twenty:
    .quad 20, 0
