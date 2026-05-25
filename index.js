// =============================================================================
// Azure VM Health Assistant — Function App Backend
// File: api/getVMs/index.js
// Route: GET /api/vms
// Returns all VMs in the subscription with live metrics
// =============================================================================

const { ComputeManagementClient } = require('@azure/arm-compute');
const { MonitorClient } = require('@azure/arm-monitor');
// const { AlertsManagementClient } = require('@azure/arm-alertsmanagement'); // FIX: correct alerts SDK
const { DefaultAzureCredential, ClientSecretCredential } = require('@azure/identity');

// ---------------------------------------------------------------------------
// Auth — prefer Managed Identity in production; fall back to SP for local dev
// FIX: inverted priority — MI is now preferred in Azure (NODE_ENV=production)
// ---------------------------------------------------------------------------

function getCredential() {
  if (
    process.env.NODE_ENV !== 'production' &&
    process.env.AZURE_CLIENT_SECRET &&
    process.env.AZURE_CLIENT_ID &&
    process.env.AZURE_TENANT_ID
  ) {
    // Service Principal — local development only
    return new ClientSecretCredential(
      process.env.AZURE_TENANT_ID,
      process.env.AZURE_CLIENT_ID,
      process.env.AZURE_CLIENT_SECRET
    );
  }
  // Managed Identity — used in Azure (production)
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

    // Return the most recent non-null value
    const latest = [...timeseries].reverse().find(d => d.average !== null);
    return latest?.average ?? null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Get active alert count for a VM
// FIX: was using monitorClient.alerts which doesn't exist; now uses the
//      correct AlertsManagementClient from @azure/arm-alertsmanagement
// ---------------------------------------------------------------------------

async function getAlertCount(alertsClient, vmName) {
  try {
    let count = 0;
    for await (const alert of alertsClient.alerts.getAll()) {
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
// Determine VM health status from live metrics
// ---------------------------------------------------------------------------

function deriveStatus(powerState, cpu, memory, disk) {
  if (
    !powerState ||
    powerState.includes('deallocated') ||
    powerState.includes('stopped')
  ) {
    return 'Stopped';
  }
  if (
    cpu > 85 ||
    (memory !== null && memory > 90) ||
    (disk !== null && disk > 90)
  ) {
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
    context.res = {
      status: 500,
      body: { error: 'AZURE_SUBSCRIPTION_ID not configured' },
    };
    return;
  }

  try {
    const credential = getCredential();
    const computeClient = new ComputeManagementClient(credential, subscriptionId);
    const monitorClient = new MonitorClient(credential, subscriptionId);
    // FIX: use AlertsManagementClient (separate SDK) instead of MonitorClient
    const alertsClient = new AlertsManagementClient(credential, subscriptionId);

    const vmList = [];

    // List all VMs in the subscription
    for await (const vm of computeClient.virtualMachines.listAll()) {
      try {
        // Derive resource group from ARM resource ID
        const resourceGroupName = vm.id.split('/')[4];

        // Get instance view for power state
        const instanceView = await computeClient.virtualMachines.instanceView(
          resourceGroupName,
          vm.name
        );

        const powerState =
          instanceView.statuses
            ?.find(s => s.code?.startsWith('PowerState/'))
            ?.code?.replace('PowerState/', '') ?? 'unknown';

        const isStopped =
          powerState === 'deallocated' || powerState === 'stopped';

        // Fetch metrics in parallel — skip if VM is stopped (no data available)
        let cpu = 0,
          memoryAvailableBytes = null,
          diskQueueDepth = null,
          networkInBytes = null,
          networkOutBytes = null;

        if (!isStopped) {
          [
            cpu,
            memoryAvailableBytes,
            diskQueueDepth,
            networkInBytes,
            networkOutBytes,
          ] = await Promise.all([
            getVMMetric(monitorClient, vm.id, 'Percentage CPU'),
            getVMMetric(monitorClient, vm.id, 'Available Memory Bytes'),
            getVMMetric(monitorClient, vm.id, 'OS Disk Queue Depth'),
            getVMMetric(monitorClient, vm.id, 'Network In Total'),
            getVMMetric(monitorClient, vm.id, 'Network Out Total'),
          ]);
        }

        // Convert available memory bytes → used percentage
        // NOTE: vmSizeRamMap covers common SKUs; for full coverage query
        //       computeClient.virtualMachineSizes.list(location) at startup.
        const vmSizeRamMap = {
          Standard_B1s: 1,
          Standard_B2s: 4,
          Standard_B4ms: 16,
          Standard_D2s_v3: 8,
          Standard_D4s_v3: 16,
          Standard_D8s_v3: 32,
          Standard_E4s_v4: 32,
          Standard_E8s_v4: 64,
          Standard_A2_v2: 4,
          Standard_DS2_v2: 7,
          Standard_D2_v3: 8,
          Standard_D4_v3: 16,
          Standard_D8_v3: 32,
          Standard_F2s_v2: 4,
          Standard_F4s_v2: 8,
          Standard_F8s_v2: 16,
          Standard_E16s_v4: 128,
          Standard_E32s_v4: 256,
        };
        const totalRamGB = vmSizeRamMap[vm.hardwareProfile?.vmSize] ?? 8;
        const totalRamBytes = totalRamGB * 1024 * 1024 * 1024;
        const memoryUsedPercent =
          memoryAvailableBytes !== null
            ? Math.min(
                100,
                Math.round(
                  ((totalRamBytes - memoryAvailableBytes) / totalRamBytes) * 100
                )
              )
            : 0;

        // FIX: disk queue depth scaled to 0-100% using 50 as the danger threshold
        // (was incorrectly dividing by 100 then multiplying by 100 — a no-op)
        const diskPercent =
          diskQueueDepth !== null
            ? Math.min(100, Math.round((diskQueueDepth / 50) * 100))
            : 0;

        // FIX: Network In/Out Total is cumulative bytes over the 5-min window.
        // Divide by interval seconds for true MB/s rate.
        // (was dividing by 60 which gave MB/min, not MB/s as commented)
        const INTERVAL_SECONDS = 5 * 60; // matches the 5-min timeRange in getVMMetric
        const networkInMBs =
          networkInBytes !== null
            ? Math.round(networkInBytes / (1024 * 1024 * INTERVAL_SECONDS))
            : 0;
        const networkOutMBs =
          networkOutBytes !== null
            ? Math.round(networkOutBytes / (1024 * 1024 * INTERVAL_SECONDS))
            : 0;

        const cpuRounded = Math.round(cpu ?? 0);
        const alerts = await getAlertCount(alertsClient, vm.name);
        const status = deriveStatus(powerState, cpuRounded, memoryUsedPercent, diskPercent);

        vmList.push({
          id: vm.id,
          name: vm.name,
          region: vm.location,
          size: vm.hardwareProfile?.vmSize ?? 'Unknown',
          os: vm.storageProfile?.imageReference?.offer
            ? `${vm.storageProfile.imageReference.offer} ${
                vm.storageProfile.imageReference.sku ?? ''
              }`.trim()
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
        'Cache-Control': 'no-cache, max-age=60',
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
