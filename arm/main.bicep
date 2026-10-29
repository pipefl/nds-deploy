// EMP from the warehouse: a network, a compute gallery with the EMP image staged from the
// distribution storage account, and the EMP VM. mainTemplate.json is built from this file:
//   az bicep build --file arm/main.bicep --outfile arm/mainTemplate.json

@description('Azure region for everything in this deployment.')
param location string = resourceGroup().location

@description('Tags applied to every resource this template creates.')
param tags object = {
  workload: 'fileds'
}

// ── EMP VM ──
@description('Name of the EMP virtual machine.')
param empName string = 'emp01'

@description('Size of the EMP virtual machine. EMP and its collector fit in 2 vCPUs and 8 GiB.')
param empSize string = 'Standard_B2ms'

@description('Administrator user on the EMP VM.')
param adminUsername string = 'fdsadmin'

@description('password or sshPublicKey.')
@allowed([
  'password'
  'sshPublicKey'
])
param authenticationType string = 'password'

@description('Password or SSH public key for the administrator.')
@secure()
param adminPasswordOrKey string

@description('Give EMP a public IP address.')
param publicIp bool = true

@description('Private IP for EMP on the management subnet. Empty: host 50 of the subnet.')
param empPrivateIp string = ''

// ── network ──
@description('new creates the virtual network and both subnets with an NSG on each; existing uses them as they are.')
@allowed([
  'new'
  'existing'
])
param vnetNewOrExisting string = 'new'

@description('Virtual network name.')
param vnetName string = 'vnet-fileds'

@description('Resource group of an existing virtual network.')
param vnetResourceGroup string = resourceGroup().name

@description('Address space of a new virtual network.')
param vnetAddressPrefixes array = [
  '10.30.0.0/16'
]

@description('Management subnet: EMP and the controllers\' management NICs.')
param mgmtSubnetName string = 'snet-mgmt'

@description('Address prefix of the management subnet.')
param mgmtSubnetPrefix string = '10.30.0.0/24'

@description('Data subnet: the controllers\' data NICs, where clients mount and log in.')
param dataSubnetName string = 'snet-data'

@description('Address prefix of the data subnet.')
param dataSubnetPrefix string = '10.30.1.0/24'

@description('Addresses or CIDRs allowed in on every port (rule admin_any_in on both NSGs). New network only.')
param adminSourceAddresses array = []

// ── image ──
@description('Storage account holding the EMP VHDs.')
param warehouseAccount string = 'nds10192026'

@description('Container with emp-<version>.vhd blobs.')
param warehouseContainer string = 'emp'

@description('SAS with read and list on the container.')
@secure()
param warehouseSas string

@description('EMP version to deploy, x.y.z, or latest for the newest VHD in the container.')
param empVersion string = 'latest'

@description('Compute gallery for the EMP image (and later the controller images). Empty: gal_<resource group>.')
param galleryName string = ''

var gallery = empty(galleryName) ? 'gal_${replace(replace(toLower(resourceGroup().name), '-', '_'), '(', '')}' : galleryName
var newVnet = vnetNewOrExisting == 'new'
var mgmtSubnetId = resourceId(newVnet ? resourceGroup().name : vnetResourceGroup, 'Microsoft.Network/virtualNetworks/subnets', vnetName, mgmtSubnetName)
var privateIp = empty(empPrivateIp) ? cidrHost(mgmtSubnetPrefix, 49) : empPrivateIp
var stagingName = 'stvhd${take(uniqueString(resourceGroup().id), 13)}'

// ── NSGs: same rules as the lab; inside means this vnet ──
var adminRule = {
  name: 'admin_any_in'
  properties: {
    priority: 110
    direction: 'Inbound'
    access: 'Allow'
    protocol: '*'
    sourceAddressPrefixes: adminSourceAddresses
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '*'
  }
}
var adminRules = empty(adminSourceAddresses) ? [] : [adminRule]

func rule(name string, priority int, protocol string, sources array, ports array) object => {
  name: name
  properties: {
    priority: priority
    direction: 'Inbound'
    access: 'Allow'
    protocol: protocol
    sourceAddressPrefixes: sources
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRanges: ports
  }
}

resource mgmtNsg 'Microsoft.Network/networkSecurityGroups@2026-07-01' = if (newVnet) {
  name: 'nsg-${vnetName}-${mgmtSubnetName}'
  location: location
  tags: tags
  properties: {
    securityRules: concat([
      rule('admin-ssh-https', 100, 'Tcp', vnetAddressPrefixes, ['22', '443'])
      rule('cluster-store-and-relay', 115, 'Tcp', [mgmtSubnetPrefix], ['2379-2380', '443'])
      rule('mgmt-name-dns', 120, '*', vnetAddressPrefixes, ['53'])
    ], adminRules)
  }
}

resource dataNsg 'Microsoft.Network/networkSecurityGroups@2026-07-01' = if (newVnet) {
  name: 'nsg-${vnetName}-${dataSubnetName}'
  location: location
  tags: tags
  properties: {
    securityRules: concat([
      rule('smb-nfs', 100, 'Tcp', vnetAddressPrefixes, ['2049', '445'])
      rule('nes-peer-rpc', 105, 'Tcp', [dataSubnetPrefix], ['7400'])
      rule('namespace-dns', 115, '*', vnetAddressPrefixes, ['53'])
      rule('iscsi', 120, 'Tcp', vnetAddressPrefixes, ['3260'])
    ], adminRules)
  }
}

// NSGs sit on the subnets, never on NICs
resource vnet 'Microsoft.Network/virtualNetworks@2026-07-01' = if (newVnet) {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: vnetAddressPrefixes
    }
    subnets: [
      {
        name: mgmtSubnetName
        properties: {
          addressPrefix: mgmtSubnetPrefix
          networkSecurityGroup: { id: mgmtNsg.id }
        }
      }
      {
        name: dataSubnetName
        properties: {
          addressPrefix: dataSubnetPrefix
          networkSecurityGroup: { id: dataNsg.id }
        }
      }
    ]
  }
}

// ── EMP image: warehouse -> staging account -> gallery ──
resource staging 'Microsoft.Storage/storageAccounts@2026-09-01' = {
  name: stagingName
  location: location
  tags: union(tags, { role: 'vhd-staging' })
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
  }
  resource blob 'blobServices' = {
    name: 'default'
    resource vhd 'containers' = {
      name: 'vhd'
    }
  }
}

resource stage 'Microsoft.Resources/deploymentScripts@2026-04-01' = {
  name: 'stage-emp-vhd'
  location: location
  tags: tags
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.61.0'
    retentionInterval: 'PT1H'
    timeout: 'PT2H'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'DEFINITION', value: 'emp' }
      { name: 'VERSION', value: empVersion }
      { name: 'WH_ACCOUNT', value: warehouseAccount }
      { name: 'WH_CONTAINER', value: warehouseContainer }
      { name: 'WH_SAS', secureValue: warehouseSas }
      { name: 'ST_ACCOUNT', value: staging.name }
      { name: 'ST_KEY', secureValue: staging.listKeys().keys[0].value }
      { name: 'STORAGE_SUFFIX', value: environment().suffixes.storage }
    ]
    scriptContent: loadTextContent('../scripts/stage-vhd.sh')
  }
  dependsOn: [
    staging::blob::vhd
  ]
}

resource gal 'Microsoft.Compute/galleries@2026-03-03' = {
  name: gallery
  location: location
  tags: tags
  properties: {
    description: 'FileDS controller and EMP images'
  }
}

resource empDef 'Microsoft.Compute/galleries/images@2026-03-03' = {
  parent: gal
  name: 'emp'
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    identifier: {
      publisher: 'FileDS'
      offer: 'FileDS'
      sku: 'emp'
    }
    features: [
      { name: 'IsAcceleratedNetworkSupported', value: 'true' }
    ]
    description: 'EMP: FileDS deployer and management'
  }
}

// the version's name is only known once the script has looked in the warehouse
module empImage 'image-version.bicep' = {
  name: 'emp-image-version'
  params: {
    location: location
    galleryName: gal.name
    definitionName: empDef.name
    version: stage.properties.outputs.version
    sourceUri: stage.properties.outputs.uri
    storageAccountId: staging.id
    tags: union(tags, {
      source: stage.properties.outputs.blob
      built: stage.properties.outputs.built
    })
  }
}

// the staged copy has done its job
resource unstage 'Microsoft.Resources/deploymentScripts@2026-04-01' = {
  name: 'unstage-emp-vhd'
  location: location
  tags: tags
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.61.0'
    retentionInterval: 'PT1H'
    timeout: 'PT15M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'BLOB', value: stage.properties.outputs.blob }
      { name: 'ST_ACCOUNT', value: staging.name }
      { name: 'ST_KEY', secureValue: staging.listKeys().keys[0].value }
      { name: 'IMAGE', value: empImage.outputs.id }
    ]
    scriptContent: 'az storage blob delete --account-name "$ST_ACCOUNT" --account-key "$ST_KEY" --container-name vhd --name "$BLOB" -o none && echo "deleted $BLOB"'
  }
}

// ── EMP VM ──
resource pip 'Microsoft.Network/publicIPAddresses@2026-07-01' = if (publicIp) {
  name: '${empName}-pip'
  location: location
  tags: union(tags, { role: 'emp' })
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// no NSG on the NIC: the subnet's NSG applies
resource nic 'Microsoft.Network/networkInterfaces@2026-07-01' = {
  name: '${empName}-nic'
  location: location
  tags: union(tags, { role: 'emp' })
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: mgmtSubnetId }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIp
          publicIPAddress: publicIp ? { id: pip.id } : null
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

resource vm 'Microsoft.Compute/virtualMachines@2026-04-01' = {
  name: empName
  location: location
  tags: union(tags, { role: 'emp' })
  properties: {
    hardwareProfile: { vmSize: empSize }
    storageProfile: {
      imageReference: { id: empImage.outputs.id }
      osDisk: {
        name: '${empName}-os'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: {
      computerName: empName
      adminUsername: adminUsername
      adminPassword: authenticationType == 'password' ? adminPasswordOrKey : null
      linuxConfiguration: authenticationType == 'password' ? null : {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPasswordOrKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: { deleteOption: 'Delete' }
        }
      ]
    }
    // managed boot diagnostics, no storage account of their own
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }
    }
  }
}

var empAddress = publicIp ? pip!.properties.ipAddress : privateIp

output empUrl string = 'https://${empAddress}/'
output empPrivateIp string = privateIp
output galleryName string = gal.name
output empImageVersion string = stage.properties.outputs.version
output servicePrincipalCommand string = 'az ad sp create-for-rbac --name sp-emp-${resourceGroup().name} --role Contributor --scopes ${resourceGroup().id}'
output nextSteps string = 'Open https://${empAddress}/ (EMP needs a few minutes after first boot) and create the EMP admin. Then Settings > Azure connection: a service principal with Contributor on ${resourceGroup().name} (servicePrincipalCommand). Then Settings > Gallery > New gallery from VHDs: account ${warehouseAccount}, container fileds (or blockds), gallery ${gal.name} in ${resourceGroup().name}.'
