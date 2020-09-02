// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Opc.Ua.PubSub{
    using System;
    /// <summary>
    /// Network Message Type
    /// </summary>
    public enum NetworkMessageType {

        /// <summary>
        /// Network message with DataSetMessage
        /// </summary>
        DataSetMessagePayload = 0,

        /// <summary>
        /// Network Message with discovery request payload
        /// </summary>
        DiscoveryRequestPayload= 1,

        /// <summary>
        /// Network message with discovery response payload
        /// </summary>
        DiscoveryResponsePayload = 2
    }

    /// <summary>
    /// Network Message Type conversions
    /// </summary>
    public static class NetworkMessageTypeEx {

        /// <summary>
        /// Json flag Network Message With Data Se tMessage
        /// </summary>
        public const string DataSetMessagePayload = "ua-data";

        /// <summary>
        /// Json flag Network Message With Discovery Request Payload
        /// </summary>
        public const string DiscoveryRequestPayload = "ua-request";

        /// <summary>
        /// Json flag Network Message With Discovery Response Payload
        /// </summary>
        public const string DiscoveryResponsePayload = "ua-metadata";

        /// <summary>
        /// To Network Message Type to Json Type
        /// </summary>
        /// <param name="type"></param>
        /// <returns></returns>
        public static string ToJsonStackType(this NetworkMessageType type){
            switch (type) {
                case NetworkMessageType.DataSetMessagePayload:
                    return DataSetMessagePayload;
                case NetworkMessageType.DiscoveryRequestPayload:
                    return DiscoveryRequestPayload;
                case NetworkMessageType.DiscoveryResponsePayload:
                    return DiscoveryResponsePayload;
                default:
                    throw new ArgumentException("Invlaid Network Message Type");
            }
        }

        /// <summary>
        /// To Network Message Type to Json Type
        /// </summary>
        /// <param name="type"></param>
        /// <returns></returns>
        public static NetworkMessageType ToUadpStackType(this string type) {
            switch (type) {
                case DataSetMessagePayload:
                    return NetworkMessageType.DataSetMessagePayload;
                case DiscoveryRequestPayload:
                    return NetworkMessageType.DiscoveryRequestPayload;
                case DiscoveryResponsePayload:
                    return NetworkMessageType.DiscoveryResponsePayload;
                default:
                    throw new ArgumentException("Invlaid Network Message Type");
            }
        }
    }
}