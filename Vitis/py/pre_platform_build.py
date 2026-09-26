"""Pre-platform-build BSP settings for the zircon echo_server.

Called by build-vitis.py (args.json "pre_platform_build_script") after the
platform and its standalone domain exist and the BSP libraries are added, but
before the platform is built, with platform, domain_name and arch as kwargs.

MicroBlaze (kcu116): xiltimer's sleep timer = axi_timer_0.
  The block design has two AXI timers: axi_timer_0 for xiltimer (usleep(),
  sleep(); the Si5328 and CMAC bring-up delays use them) and axi_timer_1,
  which the application runs as its own free-running 64-bit time base
  (Vitis/common/src/timebase.c). Left at "Default", xiltimer's MicroBlaze
  sleep would be a CPU-cycle busy loop, and with two timers in the design the
  library would otherwise pick one itself. No tick timer: the application is
  fully polled (XILTIMER_en_interval_timer stays off).

Every other architecture: nothing to do (Versal keeps the tool defaults, so
its BSP is exactly what it was before this script existed).
"""

SLEEP_TIMER_MAP = {
    "microblaze": "axi_timer_0",
}


def pre_platform_build(platform, domain_name, arch):
    sleep_timer = SLEEP_TIMER_MAP.get(arch)
    if not sleep_timer:
        print(f"pre_platform_build: nothing to do for {arch}")
        return
    print(f"Setting xiltimer sleep timer: {sleep_timer} (for {arch})")
    domain = platform.get_domain(domain_name)
    domain.set_config(option="lib", param="XILTIMER_sleep_timer",
                      value=sleep_timer, lib_name="xiltimer")
