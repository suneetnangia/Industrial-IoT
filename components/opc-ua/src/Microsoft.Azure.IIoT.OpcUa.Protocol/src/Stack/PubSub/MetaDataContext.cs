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
            _metaDataMessages = new Dictionary<Tuple<string, ushort, uint?, uint?>, NetworkMessagePubSub>();
        }

        /// <summary>
        /// AddOrUpdateDataSetMetaDataType
        /// </summary>
        /// <param name="message"></param>
        public void AddOrUpdateDataSetMetaDataType(NetworkMessagePubSub message) {

            var metaDataId = new Tuple<string, ushort, uint?, uint?>(
                message.PublisherId,
                message.DiscoveryResponsePayload.DataSetWriterId,
                message.DiscoveryResponsePayload?.MetaData?.ConfigurationVersion?.MajorVersion,
                message.DiscoveryResponsePayload?.MetaData?.ConfigurationVersion?.MinorVersion);
            if (!_metaDataMessages.TryGetValue(metaDataId, out var existing)) {
                _metaDataMessages.TryAdd(metaDataId, message);
            }
        }

        /// <summary>
        /// GetDataSetMetaDataType
        /// </summary>
        /// <param name="publisherId"></param>
        /// <param name="dataSetWriterId"></param>
        /// <param name="majorVersion"></param>
        /// <param name="minorVersion"></param>
        /// <returns></returns>
        public DataSetMetaDataType GetDataSetMetaDataType(string publisherId, 
            ushort dataSetWriterId, uint? majorVersion, uint? minorVersion) {

            var metaDataId = new Tuple<string, ushort, uint?, uint?>(
                publisherId, dataSetWriterId, majorVersion, minorVersion);
            if (_metaDataMessages.TryGetValue(metaDataId, out var message)) {
                return message?.DiscoveryResponsePayload.MetaData;
            }

            return null;
        }

        private readonly Dictionary<Tuple<string, ushort, uint?, uint?>, NetworkMessagePubSub> _metaDataMessages;

    }
}