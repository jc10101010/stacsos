/* SPDX-License-Identifier: MIT */

/* StACSOS - Kernel
 *
 * Copyright (c) University of St Andrews 2024
 * Tom Spink <tcs6@st-andrews.ac.uk>
 */
#include <stacsos/kernel/arch/x86/cregs.h>
#include <stacsos/kernel/arch/x86/msr.h>
#include <stacsos/kernel/arch/x86/pit.h>
#include <stacsos/kernel/arch/x86/x86-core.h>
#include <stacsos/kernel/debug.h>
#include <stacsos/kernel/mem/memory-manager.h>
#include <stacsos/kernel/sched/thread.h>
#include <stacsos/memops.h>

using namespace stacsos;
using namespace stacsos::kernel;
using namespace stacsos::kernel::arch;
using namespace stacsos::kernel::arch::x86;
using namespace stacsos::kernel::mem;
using namespace stacsos::kernel::sched;

extern "C" void syscall_entry();

void x86_core::init()
{
	// Populate the descriptor tables (GDT, IDT, TSS)
	populate_dt();

	// Initialise the local timestamp counter
	tsc_.calibrate();

	// Initialise the Local APIC, and the Local APIC timer.
	lapic_.init();
	timer_.init();

	// Create a temporary TCB so we can take the first interrupt.  This is needed
	// because the IRQ handling code needs somewhere to store a pointer to the saved
	// context.
	temporary_tcb.context_ptr = 0;
	temporary_tcb.task_ptr = 0;
	temporary_tcb.cr3 = 0;
	temporary_tcb.kernel_stack = 0;

	// Pop a pointer to this temporary TCB into GS.  It's not a /real/ tcb structure,
	// so we can't use set_current_tcb.
	gsbase::write((u64)&temporary_tcb);

	for (int i = 0; i < 32; i++) {
		irqs_.assign_irq(i, exception_handler, this);
	}

	// Activate the syscall instruction
	msrs::ia32_lstar = (u64)syscall_entry; // syscall instruction entrypoint
	msrs::ia32_star = 0x0013'0008'0000'0000; // GDT entries for the syscall/sysret instruction
	msrs::ia32_fmask = (u64)(1 << 9); // Disable interrupts on entry to system call
}

void x86_core::set_current_tcb(const stacsos::kernel::sched::tcb *tcb)
{
	// TODO: Check if TCB is changing...

	// A pointer to the current TCB is held in the GS register.
	gsbase::write((u64)tcb);

	// Update the CR3
	cr3::write(tcb->cr3);

	// Update the TSS
	tss_.set_kernel_stack(tcb->kernel_stack);
}

stacsos::kernel::sched::tcb *x86_core::get_current_tcb() { return (stacsos::kernel::sched::tcb *)gsbase::read(); }

static void yield_handler(u8 irq_nr, void *mcontext, void *arg)
{
	x86_core *c = (x86_core *)arg;
	c->schedule();
}

void x86_core::populate_dt()
{
	// Populate the GDT, with a NULL entry, then CODE and DATA segments for KERNEL and USER mode respectively.
	gdt_.add_null(); // 0

	// Kernel Code + Data
	gdt_.add_code_segment(descriptor_privilege_level::ring0); // 08
	gdt_.add_data_segment(descriptor_privilege_level::ring0); // 10

	// User Code + Data
	gdt_.add_data_segment(descriptor_privilege_level::ring3); // 18
	gdt_.add_code_segment(descriptor_privilege_level::ring3); // 20

	// TSS descriptor
	gdt_.add_tss(tss_);		// 28

	gdt_.reload();

	// The IRQ manager takes care of the IDT
	irqs_.initialise();
	irqs_.reserve_irq(0xff, yield_handler, this);

	// The TSS is needed for swapping stacks if we're going into USER mode.
	tss_.set_kernel_stack(0);
	tss_.reload(0x28);
}

struct trampoline_data {
	u32 core_count;		   // atomic counter: each AP xadds this to claim its scratch stack
	u32 given_core_id;	   // the BSP writes the AP's id here; the AP atomically zeroes it when up
	void (*closure)(void);
} __packed;

extern "C" char _TRAMPOLINE_START, _TRAMPOLINE_END;
extern "C" trampoline_data trampoline_data_asm;
#define _TRAMPOLINE_SIZE ((u64)&_TRAMPOLINE_END - (u64)&_TRAMPOLINE_START)
#define _TRAMPOLINE_DATA_OFFSET ((u64)&trampoline_data_asm - (u64)&_TRAMPOLINE_START)

void trampoline_closure() {

	


	// Park the core.  Interrupts are still masked, so this halts for good.
	for (;;) {
		asm volatile("hlt");
	}
}

bool x86_core::remote_run() { 
	
	auto &me_bsp = this_core();

	// We need to derive where the trampoline data struct has been moved to
	pfn_t trampoline_pfn = prepare_trampoline_code();
	unsigned long trampoline_moved_phys = trampoline_pfn << PAGE_BITS;
	void* trampoline_moved_virt = phys_to_virt(trampoline_moved_phys);
	void* trampoline_moved_data_virt = trampoline_moved_virt + _TRAMPOLINE_DATA_OFFSET;
	trampoline_data* trampoline_moved_data = (trampoline_data*) trampoline_moved_data_virt;

	if (trampoline_moved_data->core_count == 0) {
		trampoline_moved_data->closure = &trampoline_closure;
	}

	// Hand this core its id.  The AP atomically zeroes this field once it is up,
	// which is how we know it is done.  View it through a volatile pointer so the
	// compiler reloads the value on every check rather than caching our store.
	volatile trampoline_data *td = trampoline_moved_data;
	td->given_core_id = id();

	// INIT, then SIPI.
	me_bsp.lapic_.send_remote_init(id());
	me_bsp.tsc_.spin(10); // Wait for 10ms...
	me_bsp.lapic_.send_remote_sipi(id(), trampoline_pfn);
	me_bsp.tsc_.spin(10);

	if (td->given_core_id == 0) {
		dprintf("bootstrap started core [%d]\n", id());
		return true;
	}

	dprintf("bootstrap failed to start core [%d]\n", id());
	return false;
}



pfn_t x86_core::prepare_trampoline_code()
{
	pfn_t target_pfn = 8; // Page eight is what they used in the example

	// Lazily copy the trampoline image exactly once. 
	static bool trampoline_prepared = false;
	if (trampoline_prepared) {
		return target_pfn;
	}

	// Copy the trampoline assembly into this page
	// Technically, we only need the 16-bit
	// code, because once we jump into 32-bit mode, we're actually executing at normal addresses.
	unsigned long target_phys_addr = target_pfn << PAGE_BITS;
	memops::memcpy(phys_to_virt(target_phys_addr), phys_to_virt((unsigned long)&_TRAMPOLINE_START), (size_t)_TRAMPOLINE_SIZE);

	trampoline_prepared = true;
	return target_pfn;
}

void x86_core::complete_remote_init()
{

	dprintf("core [%d] online\n", id());

	// Initialise and run this new core.
	init();
	run();
}

void x86_core::handle_gpf(machine_context *mc)
{
	dprintf("CORE %d - GENERAL PROTECTION FAULT\n", id());
	mc->dump();

	dump_regs();

	panic("General Protection Fault", mc);
}

void x86_core::handle_page_fault(machine_context *mc)
{
	if (memory_manager::get().try_handle_page_fault(cr2::read())) {
		return;
	}

	thread::current().stop();

	dprintf("CORE %d - UNHANDLED PAGE FAULT\n", id());
	mc->dump();

	dump_regs();

	// panic("Unhandled Page Fault", mc);
	schedule();
}

void x86_core::dump_regs()
{
	dprintf("CORE %d REGISTERS:\n", id());

	u64 fs = fsbase::read();
	u64 gs = gsbase::read();
	dprintf("   FS=%016lx   GS=%016lx\n", fs, gs);

	u64 cr0, cr2, cr3, cr4;
	cr0 = (u64)cr0::read();
	cr2 = (u64)cr2::read();
	cr3 = (u64)cr3::read();
	cr4 = (u64)cr4::read();

	dprintf("  CR0=%016lx  CR2=%016lx\n", cr0, cr2);
	dprintf("  CR3=%016lx  CR4=%016lx\n", cr3, cr4);

	struct {
		u16 size;
		u64 ptr;
	} __packed dtp;

	asm volatile("sgdt %0" : "=m"(dtp));
	dprintf("  GDT=%016lx %04x\n", dtp.ptr, dtp.size);

	asm volatile("sidt %0" : "=m"(dtp));
	dprintf("  IDT=%016lx %04x\n", dtp.ptr, dtp.size);
}
