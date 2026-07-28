.text
.globl prefetch
.align 2
prefetch:
    .seh_proc prefetch
    .seh_endprologue
    prfm pldl1keep, [x0]
    ret
    .seh_endproc

.text
.globl bootstrap_green_task
.align 2
bootstrap_green_task:
    .seh_proc bootstrap_green_task
    .seh_endprologue
    mov x0, x19   // arg0
    mov x1, x20   // arg1
    mov x30, #0   // clear LR
    ret x21
    .seh_endproc

.text
.globl swap_registers
.align 2
swap_registers:
    .seh_proc swap_registers
    .seh_endprologue
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]

    mov x2, sp
    str x2, [x0, #96]

    stp d8,  d9,  [x0, #112]
    stp d10, d11, [x0, #128]
    stp d12, d13, [x0, #144]
    stp d14, d15, [x0, #160]

    ldr x9, [x18, #0x08] // StackBase
    str x9, [x0, #176]
    ldr x9, [x18, #0x10] // StackLimit
    str x9, [x0, #184]
    ldr x9, [x18, #0x1478] // DeallocationStack
    str x9, [x0, #192]

    ldp x19, x20, [x1, #0]
    ldp x21, x22, [x1, #16]
    ldp x23, x24, [x1, #32]
    ldp x25, x26, [x1, #48]
    ldp x27, x28, [x1, #64]
    ldp x29, x30, [x1, #80]

    ldr x2, [x1, #96]
    mov sp, x2

    ldp d8,  d9,  [x1, #112]
    ldp d10, d11, [x1, #128]
    ldp d12, d13, [x1, #144]
    ldp d14, d15, [x1, #160]

    ldr x9, [x1, #176] // StackBase
    str x9, [x18, #0x08]
    ldr x9, [x1, #184] // StackLimit
    str x9, [x18, #0x10]
    ldr x9, [x1, #192] // DeallocationStack
    str x9, [x18, #0x1478]

    br x30
    .seh_endproc
