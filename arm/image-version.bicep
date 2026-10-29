// One image version from a staged VHD. A module, because the version's name comes from a
// deployment script's output.

param location string
param galleryName string
param definitionName string
param version string
param sourceUri string
param storageAccountId string
param tags object

resource ver 'Microsoft.Compute/galleries/images/versions@2026-03-03' = {
  name: '${galleryName}/${definitionName}/${version}'
  location: location
  tags: tags
  properties: {
    publishingProfile: {
      replicaCount: 1
      storageAccountType: 'Standard_LRS'
    }
    // newer API versions turn this on by default, and then the version cannot be deleted
    safetyProfile: {
      blockDeletionBeforeEndOfLife: false
    }
    storageProfile: {
      osDiskImage: {
        source: {
          storageAccountId: storageAccountId
          uri: sourceUri
        }
      }
    }
  }
}

output id string = ver.id
