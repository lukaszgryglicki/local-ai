/* vkalloc.c — probe of the FreeBSD nvidia Vulkan pinned-memory cap (asgard, 2026-09-11).
 *
 * Result on Quadro RTX 5000, nvidia 595.99.02, FreeBSD 15.1-STABLE:
 *   host-visible types (heap 1 = system RAM, type 4 = 246 MiB BAR): every single
 *   allocation <= 255 MiB succeeds, 256 MiB and above fail with
 *   VK_ERROR_OUT_OF_DEVICE_MEMORY; device-local allocations are fine up to the
 *   8 GiB tested; the pinned *total* is not capped (a second variant kept
 *   765 x 128 MiB = 95.6 GiB pinned and freed it cleanly).
 *   ggml-vulkan stages tensor_set/get through one buffer of the copy's size, so
 *   llama.cpp on this box needs --load-mode none (64 MiB chunked uploads), never
 *   --check-tensors, and --cache-ram 0 where a per-layer K/V copy can exceed 255 MiB.
 *
 * build: cc -O1 -o vkalloc vkalloc.c -lvulkan      run: ./vkalloc [device-substring]
 * The total sweep at the end uses 256 MiB chunks; on this driver it fails at once,
 * change 256u to 128u to measure the real total.
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static const char* fl(uint32_t f){static char b[128];b[0]=0;if(f&1)strcat(b,"DL|");if(f&2)strcat(b,"HV|");if(f&4)strcat(b,"HC|");if(f&8)strcat(b,"HCACHED|");return b;}
int main(int argc,char**argv){
  const char* want = argc>1?argv[1]:"Quadro";
  VkInstance inst; VkApplicationInfo ai={VK_STRUCTURE_TYPE_APPLICATION_INFO}; ai.apiVersion=VK_API_VERSION_1_1;
  VkInstanceCreateInfo ici={VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ici.pApplicationInfo=&ai;
  if(vkCreateInstance(&ici,0,&inst)){puts("no instance");return 1;}
  uint32_t n=0; vkEnumeratePhysicalDevices(inst,&n,0); VkPhysicalDevice pd[8]; vkEnumeratePhysicalDevices(inst,&n,pd);
  VkPhysicalDevice dev=0; for(uint32_t i=0;i<n;i++){VkPhysicalDeviceProperties p; vkGetPhysicalDeviceProperties(pd[i],&p); if(strstr(p.deviceName,want)){dev=pd[i]; printf("device: %s\n",p.deviceName);} }
  if(!dev){puts("device not found");return 1;}
  VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(dev,&mp);
  for(uint32_t i=0;i<mp.memoryHeapCount;i++) printf("heap %u: %.2f GiB%s\n",i,mp.memoryHeaps[i].size/1073741824.0,(mp.memoryHeaps[i].flags&1)?" DEVICE_LOCAL":"");
  for(uint32_t i=0;i<mp.memoryTypeCount;i++) printf("type %u: heap %u flags %s\n",i,mp.memoryTypes[i].heapIndex,fl(mp.memoryTypes[i].propertyFlags));
  float prio=1.0f; VkDeviceQueueCreateInfo qci={VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qci.queueCount=1; qci.pQueuePriorities=&prio;
  VkDeviceCreateInfo dci={VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; dci.queueCreateInfoCount=1; dci.pQueueCreateInfos=&qci;
  VkDevice d; if(vkCreateDevice(dev,&dci,0,&d)){puts("no device");return 1;}
  /* per-allocation size sweep on each host-visible type and the device-local type */
  for(uint32_t t=0;t<mp.memoryTypeCount;t++){
    uint32_t f=mp.memoryTypes[t].propertyFlags; if(!(f&2) && !(f&1)) continue;
    printf("-- type %u (%s heap %u)\n",t,fl(f),mp.memoryTypes[t].heapIndex);
    size_t sizes_mib[]={64,128,192,256,320,384,512,640,768,1024,1536,2048,3072,4096,8192,0};
    for(int i=0;sizes_mib[i];i++){
      VkMemoryAllocateInfo mai={VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; mai.allocationSize=sizes_mib[i]<<20; mai.memoryTypeIndex=t;
      VkDeviceMemory m; VkResult r=vkAllocateMemory(d,&mai,0,&m);
      int mapped=0; if(r==VK_SUCCESS && (f&2)){void*p; VkResult mr=vkMapMemory(d,m,0,VK_WHOLE_SIZE,0,&p); if(mr==VK_SUCCESS){mapped=1; memset(p,1,mai.allocationSize); vkUnmapMemory(d,m);} else mapped=-mr;}
      printf("  %5zu MiB: %s%s\n",sizes_mib[i], r==VK_SUCCESS?"OK":(r==VK_ERROR_OUT_OF_DEVICE_MEMORY?"ERROR_OUT_OF_DEVICE_MEMORY":r==VK_ERROR_OUT_OF_HOST_MEMORY?"ERROR_OUT_OF_HOST_MEMORY":"ERROR"), r==VK_SUCCESS?(mapped==1?" mapped+touched":(mapped==0?"":" MAP FAILED")):"");
      if(r==VK_SUCCESS) vkFreeMemory(d,m,0);
      fflush(stdout);
    }
  }
  /* total pinned capacity: keep allocating 256 MiB chunks of the HV|HC|HCACHED type until failure (cap 48 GiB) */
  uint32_t t3=0; for(uint32_t t=0;t<mp.memoryTypeCount;t++) if((mp.memoryTypes[t].propertyFlags&0xe)==0xe && !(mp.memoryTypes[t].propertyFlags&1)) t3=t;
  printf("-- total sweep, 256 MiB chunks of type %u\n",t3);
  VkDeviceMemory keep[256]; int k=0; size_t total=0;
  for(;k<192;k++){VkMemoryAllocateInfo mai={VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; mai.allocationSize=256u<<20; mai.memoryTypeIndex=t3; if(vkAllocateMemory(d,&mai,0,&keep[k])!=VK_SUCCESS) break; total+=256;}
  printf("  %d chunks OK = %zu MiB total before failure%s\n",k,total,k>=192?" (cap reached, no failure)":"");
  for(int i=0;i<k;i++) vkFreeMemory(d,keep[i],0);
  vkDestroyDevice(d,0); vkDestroyInstance(inst,0); return 0;
}
