// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Opc.Ua.PubSub {
    using System;
    using System.Collections.Generic;

    /// <summary>
    /// Encodeable Network message
    /// </summary>
    public class NetworkMessagePubSub : IEncodeable {

        /// <summary>
        /// UADP protocol version 
        /// </summary>
        public byte? UadpVersion { get; set; } = 0x01;

        /// <summary>
        /// Message type
        /// </summary>
        public NetworkMessageType MessageType { get; set; }

        /// <summary>
        /// Message content
        /// </summary>
        public uint MessageContentMask { get; set; }

        /// <summary>
        /// Message id
        /// </summary>
        public string MessageId { get; set; }

        /// <summary>
        /// Publisher identifier
        /// </summary>
        public string PublisherId { get; set; }

        /// <summary>
        /// Dataset class
        /// </summary>
        public string DataSetClassId { get; set; }

        /// <summary>
        /// Group header
        /// </summary>
        public GroupHeader GroupHeader { get; set; }

        /// <summary>
        /// Payload header 
        /// </summary>
        public List<ushort> PayloadHeader { get; set; }
        /// <summary>
        /// Timestamp
        /// </summary>
        public DateTime? Timestamp { get; set; }

        /// <summary>
        /// Picoseconds
        /// </summary>
        public ushort? PicoSeconds { get; set; }

        // TODO Promoted fields
        // TODO Security Header

        /// <summary>
        /// Chunk list
        /// </summary>
        public List<NetworkMessageChunk> Chunks {get; set;}

        /// <summary>
        /// DataSet Messages in case the payload is a Data Set Message
        /// </summary>
        public List<DataSetMessagePubSub> Messages { get; set; }

        /// <summary>
        /// DiscoveryResponsePayload 
        /// </summary>
        public DiscoveryResponsePayload DiscoveryResponsePayload { get; set; }

        /// <inheritdoc/>
        public ExpandedNodeId TypeId => ExpandedNodeId.Null;

        /// <inheritdoc/>
        public ExpandedNodeId BinaryEncodingId => ExpandedNodeId.Null;

        /// <inheritdoc/>
        public ExpandedNodeId XmlEncodingId => ExpandedNodeId.Null;

        /// <inheritdoc/>
        public void Decode(IDecoder decoder) {
            switch (decoder.EncodingType) {
                case EncodingType.Binary:
                    DecodeBinary(decoder);
                    break;
                case EncodingType.Json:
                    DecodeJson(decoder);
                    break;
                case EncodingType.Xml:
                    throw new NotSupportedException("XML encoding is not supported.");
                default:
                    throw new NotImplementedException(
                        $"Unknown encoding: {decoder.EncodingType}");
            }
        }

        /// <inheritdoc/>
        public void Decode(IDecoder decoder, MetadataContext metadataContext) {
            switch (decoder.EncodingType) {
                case EncodingType.Binary:
                    DecodeBinary(decoder, metadataContext);
                    break;
                case EncodingType.Json:
                    DecodeJson(decoder);
                    break;
                case EncodingType.Xml:
                    throw new NotSupportedException("XML encoding is not supported.");
                default:
                    throw new NotImplementedException(
                        $"Unknown encoding: {decoder.EncodingType}");
            }
        }

        /// <inheritdoc/>
        public void Encode(IEncoder encoder) {
            switch (encoder.EncodingType) {
                case EncodingType.Binary:
                    EncodeBinary(encoder);
                    break;
                case EncodingType.Json:
                    EncodeJson(encoder);
                    break;
                case EncodingType.Xml:
                    throw new NotSupportedException("XML encoding is not supported.");
                default:
                    throw new NotImplementedException(
                        $"Unknown encoding: {encoder.EncodingType}");
            }
        }

        /// <inheritdoc/>
        public override bool Equals(Object value) {
            return IsEqual(value as IEncodeable);
        }

        /// <inheritdoc/>
        public override int GetHashCode() {
            return base.GetHashCode();
        }

        /// <inheritdoc/>
        public bool IsEqual(IEncodeable encodeable) {
            if (ReferenceEquals(this, encodeable)) {
                return true;
            }
            if (!(encodeable is NetworkMessagePubSub wrapper)) {
                return false;
            }
            if (!Utils.IsEqual(wrapper.MessageContentMask, MessageContentMask) ||
                !Utils.IsEqual(wrapper.MessageId, MessageId) ||
                !Utils.IsEqual(wrapper.DataSetClassId, DataSetClassId) ||
                !Utils.IsEqual(wrapper.BinaryEncodingId, BinaryEncodingId) ||
                !Utils.IsEqual(wrapper.MessageType, MessageType) ||
                !Utils.IsEqual(wrapper.PublisherId, PublisherId) ||
                !Utils.IsEqual(wrapper.TypeId, TypeId) ||
                !Utils.IsEqual(wrapper.XmlEncodingId, XmlEncodingId)) {
                // TODO
                return false;
            }
            return true;
        }

        /// <summary>
        /// Decode from binary
        /// </summary>
        /// <param name="decoder"></param>
        /// <param name="metadataContext"></param>
        private void DecodeBinary(IDecoder decoder, MetadataContext metadataContext = null) {

            var networkMessageHeader = decoder.ReadByte("NetworkMessageHeader");
            UadpVersion = (byte?)(networkMessageHeader & 0x0f);
            var isPublisherIdEnabled = (networkMessageHeader & 0x10) != 0;
            var isGroupHeaderEnbled = (networkMessageHeader & 0x20) != 0;
            var isPayloadHeaderEnbled = (networkMessageHeader & 0x40) != 0;
            var isExtendedFlags1Enbled = (networkMessageHeader & 0x80) != 0;
            var extendedFlags1 = isExtendedFlags1Enbled ? decoder.ReadByte("ExtendedFlags1") : (byte)0;
            var publisherType = extendedFlags1 & 0x07;
            var isDataSetClassIdEnabled = (extendedFlags1 & 0x08) != 0;
            var isSecurityEnabled = (extendedFlags1 & 0x10) != 0;
            var isTimestampEnabled = (extendedFlags1 & 0x20) != 0;
            var isPicosecondsEnabled = (extendedFlags1 & 0x40) != 0;
            var isExtendedFlags2Enabled = (extendedFlags1 & 0x80) != 0;
            var extendedFlags2 = isExtendedFlags2Enabled ? decoder.ReadByte("ExtendedFlags2") : (byte)0;
            var isChunkMessage = (extendedFlags2 & 0x01) != 0;
            var isPromotedFieldsEnabled = (extendedFlags2 & 0x02) != 0;
            MessageType = (NetworkMessageType)(extendedFlags2 >> 2 & 0x07);
            // TODO set the right MessageType
            if (isPublisherIdEnabled) {
                switch (publisherType) {
                    case 0: // Byte 
                        PublisherId = decoder.ReadByte("PublisherId").ToString();
                        break;
                    case 1: // UInt16
                        PublisherId = decoder.ReadUInt16("PublisherId").ToString();
                        break;
                    case 2: // UInt32
                        PublisherId = decoder.ReadUInt32("PublisherId").ToString();
                        break;
                    case 3: // UInt64
                        PublisherId = decoder.ReadUInt64("PublisherId").ToString();
                        break;
                    case 4: // String
                        PublisherId = decoder.ReadString("PublisherId").ToString();
                        break;
                    default:
                        // illegal value throw
                        throw new Exception("Decoding falied due to illegal publisher type: " + publisherType);
                }
            }
            DataSetClassId = isDataSetClassIdEnabled ? 
                decoder.ReadGuid("DataSetClassId").ToString() : null;
            if (isGroupHeaderEnbled) {
                GroupHeader = new GroupHeader();
                var groupFlags = decoder.ReadByte("GroupFlags");
                var isWriterGroupIdEnabled = (groupFlags & 0x01) != 0;
                var isGroupVersionEnabled = (groupFlags & 0x02) != 0;
                var isNetworkMessageNumberEnabled = (groupFlags & 0x04) != 0;
                var isSequenceNumberEnabled = (groupFlags & 0x08) != 0;

                GroupHeader.WriterGroupId = isWriterGroupIdEnabled ? 
                    (ushort?)decoder.ReadUInt16("WriterGroupId") : null;
                if (isGroupVersionEnabled) {
                    GroupHeader.GroupVersion = 
                        decoder.ReadEncodeable("GroupVersion", typeof(ConfigurationVersionDataType)) 
                        as ConfigurationVersionDataType;
                }

                GroupHeader.NetworkMessageNumber = isNetworkMessageNumberEnabled ? 
                    (ushort?)decoder.ReadUInt16("NetworkMessageNumber") : null;
                GroupHeader.SequenceNumber = isSequenceNumberEnabled ? 
                    (ushort?)decoder.ReadUInt16("SequenceNumber") : null;
            }

            var messageCount = (byte)0;
            PayloadHeader = new List<ushort>();
            if (isChunkMessage) {
                messageCount = 1;
                PayloadHeader.Add(decoder.ReadUInt16("PayloadHeader"));
            }
            else {
                messageCount = isPayloadHeaderEnbled ? decoder.ReadByte("MessageCount") : (byte)0;
                if (messageCount > 0) {
                    for (var index = 0; index < messageCount; index++) {
                        PayloadHeader.Add(decoder.ReadUInt16("PayloadHeader"));
                    }
                }
            }

            Timestamp = isTimestampEnabled ? (DateTime?)decoder.ReadDateTime("timestamp") : null;
            PicoSeconds = isPicosecondsEnabled ? (ushort?)decoder.ReadUInt16("picoseconds") : null;

            if (isPromotedFieldsEnabled) {
                var promotedFieldsSize = decoder.ReadUInt16("PromotedFieldsSize");
                for (var index = 0;index < promotedFieldsSize; index++) {
                    // TODO process further promoted fields
                }
            }

            var securityFooterSize = (UInt16)0;
            if (isSecurityEnabled) {
                var securityFlags = decoder.ReadByte("SecurityFlags");
                var isNetworkMessageSigned = (securityFlags & 0x01) != 0;
                var isNetworkMessageEncrypted = (securityFlags & 0x02) != 0;
                var isSecurityFooterEnabled = (securityFlags & 0x04) != 0;
                var isForceKeyResetEnabled = (securityFlags & 0x08) != 0;
                var securityTokenId = decoder.ReadUInt32("SecurityTokenId");
                var messageNonce = decoder.ReadByteArray("MessageNonce");
                securityFooterSize = decoder.ReadUInt16("SecurityFooterSize");
            }
            if (isChunkMessage) {
                Chunks = new List<NetworkMessageChunk>();
                var chunk = new NetworkMessageChunk();
                chunk.DataSetWriterId = PayloadHeader[0];
                chunk.MessageSequenceNumber = decoder.ReadUInt16("MessageSequenceNumber");
                chunk.ChunkOffset = decoder.ReadUInt32("ChunkOffset");
                chunk.TotalSize = decoder.ReadUInt32("TotalSize");
                chunk.ChunkData = decoder.ReadByteString("ChunkData");
                Chunks.Add(chunk);
            }
            else {
                switch (MessageType) {
                    case NetworkMessageType.DataSetMessagePayload:
                        if (messageCount > 1) {
                            var messageSizes = new ushort[messageCount];
                            for (var index = 0; index < messageCount; index++) {
                                messageSizes[index] = decoder.ReadUInt16("Sizes");
                            }
                        }
                        Messages = new List<DataSetMessagePubSub>();
                        for (var index = 0; index < messageCount; index++) {
                            var message = new DataSetMessagePubSub();
                            message.PublisherId = PublisherId;
                            message.DataSetWriterId = PayloadHeader[index];
                            message.Decode(decoder, metadataContext);
                            Messages.Add(message);
                        }
                        break;
                    case NetworkMessageType.DiscoveryRequestPayload:
                        throw new NotImplementedException("DiscoveryRequestPayload not implemented.");
                    case NetworkMessageType.DiscoveryResponsePayload:
                        DiscoveryResponsePayload = decoder.ReadEncodeable("DiscoveryResponsePayload",
                            typeof(DiscoveryResponsePayload)) as DiscoveryResponsePayload;
                        break;
                    default:
                        throw new Exception("Invalid message network type.");
                }
            }

            if (isSecurityEnabled) {
                var securityFooter = securityFooterSize > 0 ? decoder.ReadByteArray("SecurityFooter") : null;
                var signature = decoder.ReadByteArray("Signature");
            }
        }

        /// <inheritdoc/>
        private void DecodeJson(IDecoder decoder) {
            MessageContentMask = 0;
            MessageId = decoder.ReadString(nameof(MessageId));
            if (MessageId != null) {
                MessageContentMask |= (uint)JsonNetworkMessageContentMask.NetworkMessageHeader;
            }
            PublisherId = decoder.ReadString(nameof(PublisherId));
            if (PublisherId != null) {
                MessageContentMask |= (uint)JsonNetworkMessageContentMask.PublisherId;
            }
            DataSetClassId = decoder.ReadString(nameof(DataSetClassId));
            if (DataSetClassId != null) {
                MessageContentMask |= (uint)JsonNetworkMessageContentMask.DataSetClassId;
            }
            var messageType = decoder.ReadString(nameof(MessageType));
            MessageType = messageType.ToUadpStackType();
            switch (MessageType) {
                case NetworkMessageType.DataSetMessagePayload:
                    var messagesArray = decoder.ReadEncodeableArray("Messages", typeof(DataSetMessagePubSub));
                    Messages = new List<DataSetMessagePubSub>();
                    foreach (var value in messagesArray) {
                        Messages.Add(value as DataSetMessagePubSub);
                    }
                    if (Messages.Count == 1) {
                        MessageContentMask |= (uint)JsonNetworkMessageContentMask.SingleDataSetMessage;
                    }
                    break;
                case NetworkMessageType.DiscoveryRequestPayload:
                    throw new NotImplementedException("DiscoveryRequestPayload not implemented.");
                case NetworkMessageType.DiscoveryResponsePayload:
                    DiscoveryResponsePayload = decoder.ReadEncodeable("DiscoveryResponsePayload",
                            typeof(DiscoveryResponsePayload)) as DiscoveryResponsePayload;
                    break;
                default:
                    throw new Exception("Invalid message network type.");
            }
        }

        /// <summary>
        /// Encode as binary
        /// </summary>
        /// <param name="encoder"></param>
        private void EncodeBinary(IEncoder encoder) {
        }

        /// <summary>
        /// Encode as json
        /// </summary>
        /// <param name="encoder"></param>
        private void EncodeJson(IEncoder encoder) {
            if ((MessageContentMask & (uint)JsonNetworkMessageContentMask.NetworkMessageHeader) != 0) {
                encoder.WriteString(nameof(MessageId), MessageId);
                encoder.WriteString(nameof(MessageType), MessageType.ToJsonStackType());
                if ((MessageContentMask & (uint)JsonNetworkMessageContentMask.PublisherId) != 0) {
                    encoder.WriteString(nameof(PublisherId), PublisherId);
                }
                if ((MessageContentMask & (uint)JsonNetworkMessageContentMask.DataSetClassId) != 0) {
                    encoder.WriteString(nameof(DataSetClassId), DataSetClassId);
                }
                switch (MessageType) {
                    case NetworkMessageType.DataSetMessagePayload:
                        if (Messages != null && Messages.Count > 0) {
                            if ((MessageContentMask & (uint)JsonNetworkMessageContentMask.SingleDataSetMessage) != 0) {
                                encoder.WriteEncodeable(nameof(Messages), Messages[0], typeof(DataSetMessagePubSub));
                            }
                            else {
                                encoder.WriteEncodeableArray(nameof(Messages), Messages.ToArray(), typeof(DataSetMessage[]));
                            }
                        }
                        break;
                    case NetworkMessageType.DiscoveryResponsePayload:
                        if (DiscoveryResponsePayload != null) {
                            encoder.WriteUInt16(nameof(DiscoveryResponsePayload.DataSetWriterId), DiscoveryResponsePayload.DataSetWriterId);
                            encoder.WriteEncodeable(nameof(DiscoveryResponsePayload.MetaData), DiscoveryResponsePayload.MetaData, typeof(DataSetMetaDataType));
                        }
                        break;
                }
            }
        }
    }
}
