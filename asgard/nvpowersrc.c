/*
 * nvpowersrc — query / set the NVIDIA RM "perf power source" (AC vs battery)
 * through the resource-manager ioctl API on /dev/nvidiactl.
 *
 * Why: on FreeBSD the nvidia kernel driver does not appear to receive the
 * AC-adapter ACPI notification (_PSR change) that the Linux driver uses to call
 * NV2080_CTRL_CMD_PERF_SET_POWERSTATE.  After an AC loss the RM keeps the
 * battery perf cap (Quadro RTX 5000: P3, 1035 MHz SM, 5000 MHz mem, "Idle"
 * clock reason) even after AC is plugged back in.  Both controls are flagged
 * RMCTRL_FLAGS_NON_PRIVILEGED in open-gpu-kernel-modules, so this is a plain
 * user-space replay of what the driver does itself on Linux.
 *
 * Build:  cc -O2 -Wall -o ~/local-ai-runs/nvpowersrc nvpowersrc.c
 * Usage:  nvpowersrc            # print the RM's current belief (ac|battery)
 *         nvpowersrc ac         # tell the RM we are on AC
 *         nvpowersrc battery    # tell the RM we are on battery
 * Exit status: 0 ok, 1 usage, 2 ioctl/RM failure.
 */
#include <sys/ioctl.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef uint32_t NvU32;
typedef uint32_t NvHandle;
typedef uint64_t NvP64;

/* nvos.h — NVOS64_PARAMETERS (48 bytes, what nvidia-smi uses for NV_ESC_RM_ALLOC) */
typedef struct {
    NvHandle hRoot, hObjectParent, hObjectNew;
    NvU32    hClass;
    NvP64    pAllocParms      __attribute__((aligned(8)));
    NvP64    pRightsRequested __attribute__((aligned(8)));
    NvU32    paramsSize, flags, status;
} NVOS64_PARAMETERS;

/* nvos.h — NVOS54_PARAMETERS (32 bytes, NV_ESC_RM_CONTROL) */
typedef struct {
    NvHandle hClient, hObject;
    NvU32    cmd, flags;
    NvP64    params __attribute__((aligned(8)));
    NvU32    paramsSize, status;
} NVOS54_PARAMETERS;

/* nvos.h — NVOS00_PARAMETERS (16 bytes, NV_ESC_RM_FREE) */
typedef struct {
    NvHandle hRoot, hObjectParent, hObjectOld;
    NvU32    status;
} NVOS00_PARAMETERS;

/* class/cl0080.h */
typedef struct {
    NvU32    deviceId;
    NvHandle hClientShare, hTargetClient, hTargetDevice;
    NvU32    flags;
    uint64_t vaSpaceSize     __attribute__((aligned(8)));
    uint64_t vaStartInternal __attribute__((aligned(8)));
    uint64_t vaLimitInternal __attribute__((aligned(8)));
    NvU32    vaMode;
} NV0080_ALLOC_PARAMETERS;

/* class/cl2080.h */
typedef struct { NvU32 subDeviceId; } NV2080_ALLOC_PARAMETERS;

/* nv-ioctl.h */
typedef struct { int ctl_fd; } nv_ioctl_register_fd_t;

#define NV_IOCTL_MAGIC        'F'
#define NV_ESC_REGISTER_FD    201
#define NV_ESC_RM_FREE        0x29
#define NV_ESC_RM_CONTROL     0x2A
#define NV_ESC_RM_ALLOC       0x2B

#define NV01_ROOT             0x0000
#define NV01_DEVICE_0         0x0080
#define NV20_SUBDEVICE_0      0x2080

#define NV2080_CTRL_CMD_PERF_GET_POWERSTATE 0x2080205a
#define NV2080_CTRL_CMD_PERF_SET_POWERSTATE 0x2080205b
#define NV2080_CTRL_CMD_PERF_SET_AUX_POWER_STATE    0x20802092
#define NV2080_CTRL_CMD_PERF_RATED_TDP_GET_STATUS   0x2080206d
#define NV2080_CTRL_CMD_PERF_RATED_TDP_GET_CONTROL  0x2080206e
#define NV2080_CTRL_CMD_PERF_RATED_TDP_SET_CONTROL  0x2080206f
#define NV2080_CTRL_PERF_POWER_SOURCE_AC      0
#define NV2080_CTRL_PERF_POWER_SOURCE_BATTERY 1

#define H_DEVICE    0xcafe0001u
#define H_SUBDEVICE 0xcafe0002u

static int ctl = -1, dev = -1;
static NvHandle client = 0;

static void die(const char *what, int rc, NvU32 status)
{
    fprintf(stderr, "nvpowersrc: %s failed: ioctl rc=%d errno=%d rm_status=0x%x\n",
            what, rc, errno, status);
    if (client) {
        NVOS00_PARAMETERS f = { client, client, client, 0 };
        ioctl(ctl, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_FREE, NVOS00_PARAMETERS), &f);
    }
    exit(2);
}

static NvHandle rm_alloc(NvHandle parent, NvHandle hnew, NvU32 hclass, void *parms, NvU32 size)
{
    NVOS64_PARAMETERS p;
    memset(&p, 0, sizeof p);
    p.hRoot = client;
    p.hObjectParent = parent;
    p.hObjectNew = hnew;
    p.hClass = hclass;
    p.pAllocParms = (NvP64)(uintptr_t)parms;
    p.paramsSize = size;
    int rc = ioctl(ctl, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_ALLOC, NVOS64_PARAMETERS), &p);
    if (rc != 0 || p.status != 0) {
        char buf[64];
        snprintf(buf, sizeof buf, "RM_ALLOC class 0x%x", hclass);
        die(buf, rc, p.status);
    }
    return p.hObjectNew;
}

static void rm_control(NvU32 cmd, void *parms, NvU32 size)
{
    NVOS54_PARAMETERS c;
    memset(&c, 0, sizeof c);
    c.hClient = client;
    c.hObject = H_SUBDEVICE;
    c.cmd = cmd;
    c.params = (NvP64)(uintptr_t)parms;
    c.paramsSize = size;
    int rc = ioctl(ctl, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, NVOS54_PARAMETERS), &c);
    if (rc != 0 || c.status != 0) {
        char buf[64];
        snprintf(buf, sizeof buf, "RM_CONTROL 0x%x", cmd);
        die(buf, rc, c.status);
    }
}

/* like rm_control() but returns the RM status instead of dying */
static NvU32 rm_control_try(NvU32 cmd, void *parms, NvU32 size)
{
    NVOS54_PARAMETERS c;
    memset(&c, 0, sizeof c);
    c.hClient = client;
    c.hObject = H_SUBDEVICE;
    c.cmd = cmd;
    c.params = (NvP64)(uintptr_t)parms;
    c.paramsSize = size;
    int rc = ioctl(ctl, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, NVOS54_PARAMETERS), &c);
    return rc != 0 ? 0xffffffffu : c.status;
}

typedef struct {
    struct { NvU32 clientActiveMask; uint8_t bRegkeyLimitRatedTdp; } rm;
    NvU32 output, outputVPstate;
    NvU32 inputs[5], vPstateTypes[5];
} NV2080_CTRL_PERF_RATED_TDP_STATUS_PARAMS;

typedef struct { NvU32 client, input, vPstateType; } NV2080_CTRL_PERF_RATED_TDP_CONTROL_PARAMS;

static const char *tdp_client[5] = { "RM", "WAR_BUG_1785342", "GLOBAL", "OS", "PROFILE" };
static const char *tdp_action[5] = { "DEFAULT", "FORCE_EXCEED", "FORCE_LIMIT", "FORCE_LOCK", "FORCE_FLOOR" };
static const char *act(NvU32 a) { return a < 5 ? tdp_action[a] : "?"; }

static void tdp_show(void)
{
    NV2080_CTRL_PERF_RATED_TDP_STATUS_PARAMS st;
    memset(&st, 0, sizeof st);
    NvU32 rc = rm_control_try(NV2080_CTRL_CMD_PERF_RATED_TDP_GET_STATUS, &st, sizeof st);
    if (rc == 0) {
        printf("rated_tdp status: output=%s vpstate=%u clientActiveMask=0x%x regkeyLimit=%u\n",
               act(st.output), st.outputVPstate, st.rm.clientActiveMask, st.rm.bRegkeyLimitRatedTdp);
        for (int i = 0; i < 5; i++)
            printf("  input[%s]=%s vpstate=%u\n", tdp_client[i], act(st.inputs[i]), st.vPstateTypes[i]);
    } else
        printf("rated_tdp status: not available (rm_status=0x%x)\n", rc);
    for (NvU32 i = 0; i < 5; i++) {
        NV2080_CTRL_PERF_RATED_TDP_CONTROL_PARAMS cp = { i, 0, 0 };
        rc = rm_control_try(NV2080_CTRL_CMD_PERF_RATED_TDP_GET_CONTROL, &cp, sizeof cp);
        if (rc == 0) printf("rated_tdp control[%s]=%s vpstate=%u\n", tdp_client[i], act(cp.input), cp.vPstateType);
        else printf("rated_tdp control[%s]: rm_status=0x%x\n", tdp_client[i], rc);
    }
}

static const char *name(NvU32 ps)
{
    return ps == NV2080_CTRL_PERF_POWER_SOURCE_AC ? "ac" :
           ps == NV2080_CTRL_PERF_POWER_SOURCE_BATTERY ? "battery" : "unknown";
}

int main(int argc, char **argv)
{
    int want = -1;
    if (argc == 2 && strcmp(argv[1], "ac") == 0) want = NV2080_CTRL_PERF_POWER_SOURCE_AC;
    else if (argc == 2 && strcmp(argv[1], "battery") == 0) want = NV2080_CTRL_PERF_POWER_SOURCE_BATTERY;
    int tdp = 0, tdp_set_client = -1, tdp_set_action = -1, aux = -1;
    if (argc == 2 && strcmp(argv[1], "tdp") == 0) tdp = 1;
    else if (argc == 4 && strcmp(argv[1], "tdp-set") == 0) { tdp = 1; tdp_set_client = atoi(argv[2]); tdp_set_action = atoi(argv[3]); }
    else if (argc == 3 && strcmp(argv[1], "aux") == 0) aux = atoi(argv[2]);
    else if (want < 0 && argc != 1) {
        fprintf(stderr, "usage: nvpowersrc [ac|battery|tdp|tdp-set CLIENT(0-4) ACTION(0-4)|aux N]\n");
        return 1;
    }

    ctl = open("/dev/nvidiactl", O_RDWR);
    if (ctl < 0) { perror("open /dev/nvidiactl"); return 2; }
    dev = open("/dev/nvidia0", O_RDWR | O_CLOEXEC);
    if (dev < 0) { perror("open /dev/nvidia0"); return 2; }
    nv_ioctl_register_fd_t reg = { ctl };
    if (ioctl(dev, _IOWR(NV_IOCTL_MAGIC, NV_ESC_REGISTER_FD, nv_ioctl_register_fd_t), &reg) != 0)
        die("REGISTER_FD", -1, 0);

    client = rm_alloc(0, 0, NV01_ROOT, NULL, 0);

    NV0080_ALLOC_PARAMETERS d;
    memset(&d, 0, sizeof d);
    rm_alloc(client, H_DEVICE, NV01_DEVICE_0, &d, sizeof d);

    NV2080_ALLOC_PARAMETERS s = { 0 };
    rm_alloc(H_DEVICE, H_SUBDEVICE, NV20_SUBDEVICE_0, &s, sizeof s);

    NvU32 ps = 0xffffffffu;
    rm_control(NV2080_CTRL_CMD_PERF_GET_POWERSTATE, &ps, sizeof ps);
    printf("rm power source: %s (%u)\n", name(ps), ps);

    if (want >= 0) {
        NvU32 set = (NvU32)want;
        rm_control(NV2080_CTRL_CMD_PERF_SET_POWERSTATE, &set, sizeof set);
        ps = 0xffffffffu;
        rm_control(NV2080_CTRL_CMD_PERF_GET_POWERSTATE, &ps, sizeof ps);
        printf("rm power source now: %s (%u)\n", name(ps), ps);
    }

    if (tdp) {
        tdp_show();
        if (tdp_set_client >= 0) {
            NV2080_CTRL_PERF_RATED_TDP_CONTROL_PARAMS cp = { (NvU32)tdp_set_client, (NvU32)tdp_set_action, 0 };
            NvU32 rc = rm_control_try(NV2080_CTRL_CMD_PERF_RATED_TDP_SET_CONTROL, &cp, sizeof cp);
            printf("rated_tdp set control[%s]=%s -> rm_status=0x%x\n", tdp_client[tdp_set_client % 5], act(cp.input), rc);
            tdp_show();
        }
    }
    if (aux >= 0) {
        NvU32 a = (NvU32)aux;
        NvU32 rc = rm_control_try(NV2080_CTRL_CMD_PERF_SET_AUX_POWER_STATE, &a, sizeof a);
        printf("set aux power state P%d -> rm_status=0x%x\n", aux, rc);
    }

    NVOS00_PARAMETERS f = { client, client, client, 0 };
    ioctl(ctl, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_FREE, NVOS00_PARAMETERS), &f);
    close(dev);
    close(ctl);
    return 0;
}
