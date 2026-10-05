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
	u32 core_count;		  
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

	// Now we need to link back the closure
	trampoline_moved_data->closure = &trampoline_closure;

	// The trampoline smoke-test writes 0x6767 to physical 0x1000 once the AP comes
	// alive. Clear it first so we don't observe a stale value from a previous core.
	volatile u16 *liveness = (volatile u16 *)phys_to_virt(0x8100);
	*liveness = 0;

	// INIT, then SIPI.
	me_bsp.lapic_.send_remote_init(id());
	me_bsp.tsc_.spin(10); // Wait for 10ms...
	me_bsp.lapic_.send_remote_sipi(id(), trampoline_pfn);
	me_bsp.tsc_.spin(10); // Give the AP time to run the trampoline.

	// Report whether the AP actually executed the trampoline.
	if (*liveness == 0x6767) {
		dprintf("we have successfully started the 67 67 core");
	} else {
		dprintf("we have not successfulyl started the core");
	}
	return *liveness == 0x6767;

	// Send next sipi

	// Clear page we copied into maybe???


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

#if 0

bool x86_core::remote_run()
{
	auto &me = this_core();

	pfn_t mpstart_pfn = prepare_mpstartup_code();

	// Acquire a pointer to the mp startup data structure, which we need to fill in.  It should
	// be volatile, so that we can check the mpready flag without worrying that the compiler
	// optimises "redundant checks" away.
	volatile mpstartup_data *d = (volatile mpstartup_data *)&_MPSTARTUP_DATA;
	d->mpready = 0; // Is the core ready?
	d->mpcr3 = __read_cr3(); // The pages tables to provide the core with (just the same as this core's)
	d->core_obj = this; // A pointer to the core object that is coming online
	d->mpstack = (void *)(((u64) new char[0x1000]) + 0x1000); // A temporary stack (which we need to remember to free at some point)
	d->trampoline = &exegol::arch::x86::x86_core::complete_remote_init; // The function to call once we've gotten into 64-bit mode

	// Stick in a full memory fence, just to be safe.
	asm volatile("mfence" ::: "memory");

	// The sequence is INIT --> SIPI (--> SIPI)

	// Send the INIT
	me.lapic_.send_remote_init(id());
	me.tsc_.spin(10); // Wait for 10ms...

	// Send the SIPI
	me.lapic_.send_remote_sipi(id(), mpstart_pfn);
	me.tsc_.spin(1); // Wait for 1ms...

	// If the core didn't come online, send another SIPI and give it a second
	if (!d->mpready) {
		me.lapic_.send_remote_sipi(id(), mpstart_pfn);
		me.tsc_.spin(1000); // 1s
	}

	// Return whether or not the core came online.
	return !!d->mpready;
}



void x86_core::complete_remote_init()
{
	// Update the TSC aux MSR with the core ID, so that the rdpid instruction works.
	msr::write(msr_indicies::IA32_TSC_AUX, id());

	dprintf("core [%d] online\n", id());

	// Initialise and run this new core.
	init();
	run();
}
#endif

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
