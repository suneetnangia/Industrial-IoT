// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Opc.Ua.PubSub {
    using System.Collections.Generic;
    using System;
    using System.Linq;


    /// <summary>
    /// The metadata reporitory
    /// </summary>
    public class MetadataContext {

        /// <summary>
        /// Create default
        /// </summary>
        public MetadataContext() {
            _metaDataMessages = new Dictionary<Tuple<string, ushort>, List<NetworkMessagePubSub>>();
        }

        /// <summary>
        /// AddOrUpdateDataSetMetaDataType
        /// </summary>
        /// <param name="message"></param>
        public void AddOrUpdateDataSetMetaDataType(NetworkMessagePubSub message) {

            var discoveryResponseId = new Tuple<string, ushort>(message.PublisherId, message.DiscoveryResponsePayload.DataSetWriterId);
            if (_metaDataMessages.TryGetValue(discoveryResponseId, out var existing)) {
                existing.Add(message);
            }
            else {
                existing = new List<NetworkMessagePubSub>() { message };
                _metaDataMessages[discoveryResponseId] = existing;
            }
        }

        /// <summary>
        /// 
        /// </summary>
        /// <param name="publisherId"></param>
        /// <param name="dataSetWriterId"></param>
        /// <returns></returns>
        public DataSetMetaDataType GetDataSetMetaDataType(string publisherId, ushort dataSetWriterId) {

            var metaDataId = new Tuple<string, ushort>(publisherId, dataSetWriterId);
            if (_metaDataMessages.TryGetValue(metaDataId, out var metadataNetworkMessageList)) {
                return metadataNetworkMessageList.First()!.DiscoveryResponsePayload.MetaData;
            }

            return null;
        }

        private readonly Dictionary<Tuple<string, ushort>, List<NetworkMessagePubSub>> _metaDataMessages;

    }
}