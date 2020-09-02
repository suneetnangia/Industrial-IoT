// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Opc.Ua.PubSub {
    using System;

    /// <summary>
    /// Grpup Header of the Network message
    /// </summary>
    public class GroupHeader {

        /// <summary>
        /// Group identifier
        /// </summary>
        public ushort? WriterGroupId { get; set; }

        /// <summary>
        /// The group version
        /// </summary>
        public ConfigurationVersionDataType GroupVersion { get; set; }

        /// <summary>
        /// Uniquire number across PublisherId and WeiterGroupId
        /// </summary>
        public ushort? NetworkMessageNumber { get; set; }

        /// <summary>
        /// the sewuence number of the Network message
        /// </summary>
        public ushort? SequenceNumber { get; set; } 

    }
}