// pinprobe.c - allocate host-visible ("pinned") Vulkan memory chunks on the NVIDIA GPU and report what fails
// (asgard, FreeBSD 15.1, nvidia 595.99.02, Quadro RTX 5000; results-t0.md FAIL-infra 12:21, results-t2.md 2.3).
// build: cc -O1 -o pinprobe pinprobe.c -I/usr/local/include -L/usr/local/lib -lvulkan
// usage: pinprobe CHUNK_MIB COUNT [PRIORITY(0/1, default 1)] [DEVICE_MIB_AFTER (default 952)]
//   allocates COUNT chunks of CHUNK_MIB the way ggml does (VkBuffer + device address + vkAllocateMemory in the
//   HOST_VISIBLE|HOST_COHERENT|HOST_CACHED type + bind, all kept alive), then one DEVICE_LOCAL allocation of
//   DEVICE_MIB_AFTER to show the "poisoning" of later allocations after a failure.
//   env: PLAIN=1 plain vkAllocateMemory (no buffer), PLUS32=1 adds ggml's 32 B to the size, NOBDA=1 no buffer device
//   address, DEVFIRST_MIB=N allocate N MiB device-local first. PRIORITY=1 enables VK_EXT_memory_priority (ggml only
//   does with GGML_VK_ENABLE_MEMORY_PRIORITY; it segfaulted in the driver at window sizes on 14 Sep 09:3x).
// findings 14 Sep 2026: host-visible sizes in [n*256 MiB, n*256 MiB + w) fail, w = 1..14 MiB depending on the driver's
//   global state (idle GPU: [512,524) [768,782) [1024,1038); with another process holding 70 GiB pinned only the exact
//   multiples fail); one failure poisons the process; < 256 MiB never fails; 73 x 960 MiB (70 GiB) is fine.
//   -> patches/0002-vulkan-pad-host-alloc-windows.patch pads such sizes to n*256 MiB + 128 MiB.
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *res(VkResult r) {
  switch (r) {
    case VK_SUCCESS: return "OK";
    case VK_ERROR_OUT_OF_DEVICE_MEMORY: return "OUT_OF_DEVICE_MEMORY";
    case VK_ERROR_OUT_OF_HOST_MEMORY: return "OUT_OF_HOST_MEMORY";
    case VK_ERROR_TOO_MANY_OBJECTS: return "TOO_MANY_OBJECTS";
    default: return "other";
  }
}

int main(int argc, char **argv) {
  unsigned long long chunk = (argc > 1 ? strtoull(argv[1], 0, 10) : 960) << 20;
  int count = argc > 2 ? atoi(argv[2]) : 1;
  int prio = argc > 3 ? atoi(argv[3]) : 1;
  unsigned long long devafter = (argc > 4 ? strtoull(argv[4], 0, 10) : 952) << 20;

  VkApplicationInfo ai = { VK_STRUCTURE_TYPE_APPLICATION_INFO, 0, "pinprobe", 1, "none", 1, VK_API_VERSION_1_2 };
  VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, 0, 0, &ai, 0, 0, 0, 0 };
  VkInstance inst; if (vkCreateInstance(&ici, 0, &inst) != VK_SUCCESS) { puts("no instance"); return 2; }
  uint32_t n = 0; vkEnumeratePhysicalDevices(inst, &n, 0);
  VkPhysicalDevice pds[8]; if (n > 8) n = 8; vkEnumeratePhysicalDevices(inst, &n, pds);
  VkPhysicalDevice pd = 0;
  for (uint32_t i = 0; i < n; i++) {
    VkPhysicalDeviceProperties p; vkGetPhysicalDeviceProperties(pds[i], &p);
    if (p.vendorID == 0x10de) { pd = pds[i]; printf("device: %s\n", p.deviceName); break; }
  }
  if (!pd) { puts("no NVIDIA device"); return 2; }

  uint32_t ne = 0; vkEnumerateDeviceExtensionProperties(pd, 0, &ne, 0);
  VkExtensionProperties *ex = malloc(ne * sizeof *ex); vkEnumerateDeviceExtensionProperties(pd, 0, &ne, ex);
  int have_prio = 0;
  for (uint32_t i = 0; i < ne; i++) if (!strcmp(ex[i].extensionName, "VK_EXT_memory_priority")) have_prio = 1;
  const char *exts[2] = { "VK_EXT_memory_priority", "VK_KHR_buffer_device_address" };
  VkPhysicalDeviceBufferDeviceAddressFeatures bf = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES, 0, VK_TRUE, VK_FALSE, VK_FALSE };
  VkPhysicalDeviceMemoryPriorityFeaturesEXT pf = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PRIORITY_FEATURES_EXT, &bf, VK_TRUE };
  int bda = getenv("NOBDA") == 0;
  float qp = 1.0f;
  VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, 0, 0, 0, 1, &qp };
  if (!bda) { pf.pNext = 0; }
  VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, (prio && have_prio) ? (void*)&pf : (bda ? (void*)&bf : 0), 0, 1, &qci, 0, 0,
                             (prio && have_prio) ? (bda ? 2u : 1u) : 0u, (prio && have_prio) ? exts : exts + 1, 0 };
  if (!(prio && have_prio) && bda) { dci.enabledExtensionCount = 1; dci.ppEnabledExtensionNames = exts + 1; }
  VkDevice dev; if (vkCreateDevice(pd, &dci, 0, &dev) != VK_SUCCESS) { puts("no device"); return 2; }
  printf("memory_priority ext: %s (used: %s)\n", have_prio ? "yes" : "no", (prio && have_prio) ? "yes" : "no");

  VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
  int host_type = -1, dev_type = -1;
  VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
  for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
    VkMemoryPropertyFlags f = mp.memoryTypes[i].propertyFlags;
    if (host_type < 0 && (f & want) == want && !(f & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) host_type = i;
    if (dev_type < 0 && (f & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) && !(f & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) dev_type = i;
  }
  printf("host type %d (heap %u, %.1f GiB) device type %d (heap %u, %.1f GiB)\n", host_type, mp.memoryTypes[host_type].heapIndex,
         mp.memoryHeaps[mp.memoryTypes[host_type].heapIndex].size / 1073741824.0, dev_type, mp.memoryTypes[dev_type].heapIndex,
         mp.memoryHeaps[mp.memoryTypes[dev_type].heapIndex].size / 1073741824.0);

  VkMemoryPriorityAllocateInfoEXT pri = { VK_STRUCTURE_TYPE_MEMORY_PRIORITY_ALLOCATE_INFO_EXT, 0, 1.0f };
  int ok = 0, fail = 0; VkResult first_fail = VK_SUCCESS; unsigned long long total = 0;
  if (getenv("DEVFIRST_MIB")) { unsigned long long dsz = strtoull(getenv("DEVFIRST_MIB"), 0, 10) << 20;
    VkMemoryAllocateInfo d0 = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, (prio && have_prio) ? (void*)&pri : 0, dsz, (uint32_t)dev_type };
    VkDeviceMemory dm0; printf("device-local %llu MiB first: %s\n", dsz >> 20, res(vkAllocateMemory(dev, &d0, 0, &dm0))); }
  if (getenv("PLUS32")) chunk += 32;
  printf("mode: %s (bda=%d)\n", getenv("PLAIN") ? "plain vkAllocateMemory" : "ggml-like VkBuffer+DeviceAddress+priority", bda);
  for (int i = 0; i < count; i++) {
    VkDeviceMemory mem; VkResult r; unsigned long long asz = chunk;
    if (getenv("PLAIN")) {
      VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, (prio && have_prio) ? (void*)&pri : 0, chunk, (uint32_t)host_type };
      r = vkAllocateMemory(dev, &mai, 0, &mem);
    } else {
      VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, 0, 0, chunk,
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | (bda ? VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT : 0),
        VK_SHARING_MODE_EXCLUSIVE, 0, 0 };
      VkBuffer b; if (vkCreateBuffer(dev, &bci, 0, &b) != VK_SUCCESS) { puts("createBuffer failed"); return 3; }
      VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, b, &mr); asz = mr.size;
      uint32_t ti = 32; for (uint32_t t = 0; t < mp.memoryTypeCount; t++) if ((mr.memoryTypeBits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & want) == want && !(mp.memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { ti = t; break; }
      if (i == 0) printf("buffer mem req: %llu B (asked %llu), type %u, align %llu\n", (unsigned long long)mr.size, chunk, ti, (unsigned long long)mr.alignment);
      VkMemoryAllocateFlagsInfo fi = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, (prio && have_prio) ? (void*)&pri : 0, bda ? VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT : 0, 0 };
      VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &fi, mr.size, ti };
      r = vkAllocateMemory(dev, &mai, 0, &mem);
      if (r == VK_SUCCESS) { r = vkBindBufferMemory(dev, b, mem, 0); if (r != VK_SUCCESS) printf("bind failed: %s\n", res(r)); }
    }
    if (r == VK_SUCCESS) { ok++; total += asz; void *p; if (vkMapMemory(dev, mem, 0, asz, 0, &p) == VK_SUCCESS) { memset(p, 1, 4096); } }
    else { fail++; if (first_fail == VK_SUCCESS) { first_fail = r; printf("host chunk #%d (%llu MiB) FAILED: %s after %llu MiB ok\n", i + 1, chunk >> 20, res(r), total >> 20); } }
  }
  printf("host chunks: %d ok (%llu MiB), %d failed\n", ok, total >> 20, fail);
  VkMemoryAllocateInfo dai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, (prio && have_prio) ? (void*)&pri : 0, devafter, (uint32_t)dev_type };
  VkDeviceMemory dm; VkResult r = vkAllocateMemory(dev, &dai, 0, &dm);
  printf("device-local %llu MiB after that: %s\n", devafter >> 20, res(r));
  return fail ? 1 : 0;
}
