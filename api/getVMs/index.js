// =============================================================================
// Azure VM Health Assistant — Function App Backend
// File: api/getVMs/index.js
// Route: GET /api/vms
// Returns all VMs in the subscription with live metrics
// =============================================================================

const { ComputeManagementClient } = require('@azure/arm-compute');
const { MonitorClient } = require('@azure/arm-monitor');
const { ResourceManagementClient } = require('@azure/arm-resources');
const { DefaultAzureCredential, ClientSecretCredential } = require('@azure/identity');

// ---------------------------------------------------------------------------
// Auth — uses Managed Identity in production, SP credentials in dev
// ---------------------------------------------------------------------------

function getCredential() {
  if (process.env.AZURE_CLIENT_SECRET) {
    // Service Principal (fallback / local dev)
    return new ClientSecretCredential(
      process.env.AZURE_TENANT_ID,
      process.env.AZURE_CLIENT_ID,
      process.env.AZURE_CLIENT_SECRET
    );
  }
  // Managed Identity (preferred in Azure)
  return new DefaultAzureCredential();
}

// ---------------------------------------------------------------------------
// Fetch metric value for a single VM
// ---------------------------------------------------------------------------

async function getVMMetric(monitorClient, resourceId, metricName, timeRange = 5) {
  try {
    const endTime = new Date();
    const startTime = new Date(endTime.getTime() - timeRange * 60 * 1000);

    const result = await monitorClient.metrics.list(resourceId, {
      timespan: `${startTime.toISOString()}/${endTime.toISOString()}`,
      interval: 'PT1M',
      metricnames: metricName,
      aggregation: 'Average',
    });

    const timeseries = result.value?.[0]?.timeseries?.[0]?.data;
    if (!timeseries || timeseries.length === 0) return null;

    // Get the latest non-null value
    const latest = [...timeseries].reverse().find(d => d.average !== null);
    return latest?.average ?? null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Get active alerts count for a VM
// ---------------------------------------------------------------------------

async function getAlertCount(monitorClient, subscriptionId, vmName) {
  try {
    const alerts = monitorClient.alerts.getAll(`/subscriptions/${subscriptionId}`);
    let count = 0;
    for await (const alert of alerts) {
      if (
        alert.essentials?.targetResourceName?.toLowerCase() === vmName.toLowerCase() &&
        alert.essentials?.monitorCondition === 'Fired'
      ) {
        count++;
      }
    }
    return count;
  } catch {
    return 0;
  }
}

// ---------------------------------------------------------------------------
// Determine VM health status from metrics
// ---------------------------------------------------------------------------

function deriveStatus(vmPowerState, cpu, memory, disk) {
  if (!vmPowerState || vmPowerState.includes('deallocated') || vmPowerState.includes('stopped')) {
    return 'Stopped';
  }
  if (cpu > 85 || (memory !== null && memory > 90) || (disk !== null && disk > 90)) {
    return 'Warning';
  }
  return 'Running';
}

// ---------------------------------------------------------------------------
// Main Function Handler
// ---------------------------------------------------------------------------

module.exports = async function (context, req) {
  context.log('Azure VM Health API — fetching VM data');

  const subscriptionId = process.env.AZURE_SUBSCRIPTION_ID;
  if (!subscriptionId) {
    context.res = { status: 500, body: { error: 'AZURE_SUBSCRIPTION_ID not configured' } };
    return;
  }

  try {
    const credential = getCredential();
    const computeClient = new ComputeManagementClient(credential, subscriptionId);
    const monitorClient = new MonitorClient(credential, subscriptionId);

    const vmList = [];

    // List all VMs in subscription
    for await (const vm of computeClient.virtualMachines.listAll()) {
      try {
        // Get instance view for power state
        const resourceGroupName = vm.id.split('/')[4];
        const instanceView = await computeClient.virtualMachines.instanceView(
          resourceGroupName,
          vm.name
        );

        const powerState = instanceView.statuses
          ?.find(s => s.code?.startsWith('PowerState/'))
          ?.code?.replace('PowerState/', '') ?? 'unknown';

        const isStopped = powerState === 'deallocated' || powerState === 'stopped';

        // Fetch metrics in parallel (skip if VM is stopped)
        let cpu = 0, memoryAvailableBytes = null, diskQueueDepth = null,
            networkInBytes = null, networkOutBytes = null;

        if (!isStopped) {
          [cpu, memoryAvailableBytes, diskQueueDepth, networkInBytes, networkOutBytes] =
            await Promise.all([
              getVMMetric(monitorClient, vm.id, 'Percentage CPU'),
              getVMMetric(monitorClient, vm.id, 'Available Memory Bytes'),
              getVMMetric(monitorClient, vm.id, 'OS Disk Queue Depth'),
              getVMMetric(monitorClient, vm.id, 'Network In Total'),
              getVMMetric(monitorClient, vm.id, 'Network Out Total'),
            ]);
        }

        // Convert memory bytes → percentage (approximate based on VM size)
        // We use available bytes / total RAM; total RAM derived from VM size
        const vmSizeRamMap = {
          'Standard_B1s': 1, 'Standard_B2s': 4, 'Standard_B4ms': 16,
          'Standard_D2s_v3': 8, 'Standard_D4s_v3': 16, 'Standard_D8s_v3': 32,
          'Standard_E4s_v4': 32, 'Standard_E8s_v4': 64,
          'Standard_A2_v2': 4, 'Standard_DS2_v2': 7,
        };
        const totalRamGB = vmSizeRamMap[vm.hardwareProfile?.vmSize] ?? 8;
        const totalRamBytes = totalRamGB * 1024 * 1024 * 1024;
        const memoryUsedPercent = memoryAvailableBytes !== null
          ? Math.round(((totalRamBytes - memoryAvailableBytes) / totalRamBytes) * 100)
          : 0;

        // Disk: convert queue depth to a rough 0-100 percentage
        const diskPercent = diskQueueDepth !== null
          ? Math.min(100, Math.round((diskQueueDepth / 100) * 100))
          : 0;

        // Network in MB/s
        const networkInMBs = networkInBytes !== null
          ? Math.round(networkInBytes / (1024 * 1024 * 60)) // per minute → per second
          : 0;
        const networkOutMBs = networkOutBytes !== null
          ? Math.round(networkOutBytes / (1024 * 1024 * 60))
          : 0;

        const cpuRounded = Math.round(cpu ?? 0);
        const alerts = await getAlertCount(monitorClient, subscriptionId, vm.name);
        const status = deriveStatus(powerState, cpuRounded, memoryUsedPercent, diskPercent);

        vmList.push({
          id: vm.id,
          name: vm.name,
          region: vm.location,
          size: vm.hardwareProfile?.vmSize ?? 'Unknown',
          os: vm.storageProfile?.imageReference?.offer
            ? `${vm.storageProfile.imageReference.offer} ${vm.storageProfile.imageReference.sku ?? ''}`.trim()
            : 'Unknown',
          status,
          powerState,
          cpu: cpuRounded,
          memory: memoryUsedPercent,
          disk: diskPercent,
          network: {
            in: networkInMBs,
            out: networkOutMBs,
          },
          uptime: isStopped ? '0h' : null, // Uptime requires Log Analytics query
          alerts,
          tags: Object.keys(vm.tags ?? {}).map(k => k.toLowerCase()),
          resourceGroup: resourceGroupName,
        });

      } catch (vmErr) {
        context.log.warn(`Skipping VM ${vm.name}: ${vmErr.message}`);
      }
    }

    // Sort: Warning first, then Running, then Stopped
    vmList.sort((a, b) => {
      const order = { Warning: 0, Running: 1, Stopped: 2 };
      return (order[a.status] ?? 3) - (order[b.status] ?? 3);
    });

    context.res = {
      status: 200,
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-cache, max-age=60', // cache for 60s
      },
      body: {
        subscription: subscriptionId,
        fetchedAt: new Date().toISOString(),
        count: vmList.length,
        vms: vmList,
      },
    };

  } catch (err) {
    context.log.error('Fatal error fetching VMs:', err.message);
    context.res = {
      status: 500,
      body: { error: 'Failed to fetch VM data', detail: err.message },
    };
  }
};
