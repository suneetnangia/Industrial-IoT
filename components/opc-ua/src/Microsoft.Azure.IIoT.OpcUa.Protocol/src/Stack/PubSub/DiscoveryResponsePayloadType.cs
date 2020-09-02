// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Opc.Ua.PubSub{

    /// <summary>
    /// Discovery Response Payload Type 
    /// </summary>
    public enum DiscoveryResponsePayloadType {

        /// <summary>
        /// Publisher Endpoint Message
        /// </summary>
        PublisherEndpoint = 1,

        /// <summary>
        /// DataSet Metadata Message
        /// </summary>
        DataSetMetaData= 2,

        /// <summary>
        /// Data Set Writer Configuration Message
        /// </summary>
        DataSetWriterConfiguration = 3
    }
}