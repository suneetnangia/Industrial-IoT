// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Opc.Ua.PubSub {

    /// <summary>
    /// Encodeable dataset metadata
    /// </summary>
    public class NetworkMessageChunk {

        /// <summary>
        /// DataSetWriterId
        /// </summary>
        public ushort DataSetWriterId { get; set; }

        /// <summary>
        /// Message SequenceNumber
        /// </summary>
        public ushort MessageSequenceNumber { get; set; }

        /// <summary>
        /// Chunk Offset
        /// </summary>
        public uint ChunkOffset { get; set; }

        /// <summary>
        /// Total Size
        /// </summary>
        public uint TotalSize { get; set; }

        /// <summary>
        /// ChunkData
        /// </summary>
        public byte[] ChunkData { get; set; }
    }
}
