// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Opc.Ua.PubSub {
    using System;

    /// <summary>
    /// Data set message
    /// </summary>
    public class DiscoveryResponsePayload : IEncodeable {

        /// <summary>
        /// Payload type of the message
        /// </summary>
        DiscoveryResponsePayloadType PayloadType { get; set; }

        /// <summary>
        /// Dataset writer id
        /// </summary>
        public ushort DataSetWriterId { get; set; }

        /// <summary>
        /// Sequence number
        /// </summary>
        public uint SequenceNumber { get; set; }

        /// <summary>
        /// Status
        /// </summary>
        public StatusCode Status { get; set; }

        /// <summary>
        /// Payload
        /// </summary>
        public DataSetMetaDataType MetaData { get; set; }

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
                    throw new NotImplementedException("XML encoding is not implemented.");
                default:
                    throw new NotImplementedException($"Unknown encoding: {decoder.EncodingType}");
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
                    throw new NotImplementedException("XML encoding is not implemented.");
                default:
                    throw new NotImplementedException($"Unknown encoding: {encoder.EncodingType}");
            }
        }

        /// <inheritdoc/>
        public override bool Equals(object value) {
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
            if (!(encodeable is DataSetMessage wrapper)) {
                return false;
            }
            if (!Utils.IsEqual(wrapper.DataSetWriterId, DataSetWriterId) ||
                !Utils.IsEqual(wrapper.SequenceNumber, SequenceNumber) ||
                !Utils.IsEqual(wrapper.Status, Status) ||
                !Utils.IsEqual(wrapper.BinaryEncodingId, BinaryEncodingId) ||
                !Utils.IsEqual(wrapper.TypeId, TypeId) ||
                !Utils.IsEqual(wrapper.XmlEncodingId, XmlEncodingId)) {
                return false;
            }
            return true;
        }


        /// <inheritdoc/>
        private void EncodeBinary(IEncoder encoder) {

        }

        /// <inheritdoc/>
        private void EncodeJson(IEncoder encoder) {

        }

        /// <inheritdoc/>
        private void DecodeBinary(IDecoder decoder) {
            PayloadType = (DiscoveryResponsePayloadType)decoder.ReadByte("ResponseType");
            SequenceNumber = decoder.ReadUInt16("SequenceNumber");
            switch (PayloadType) {
                case DiscoveryResponsePayloadType.PublisherEndpoint:
                    throw new NotImplementedException("Publisher Endpoint Message not implemented.");
                case DiscoveryResponsePayloadType.DataSetMetaData: 
                    DataSetWriterId = decoder.ReadUInt16(nameof(DataSetWriterId));
                    MetaData = decoder.ReadEncodeable(nameof(MetaData), typeof(DataSetMetaDataType))
                            as DataSetMetaDataType;
                    Status = decoder.ReadStatusCode("StatusCode");
                    break;
                case DiscoveryResponsePayloadType.DataSetWriterConfiguration:
                    throw new NotImplementedException("DataSetWriter Configuration Message not implemented.");
                default:
                    throw new Exception("Invalid response type");
            }
        }

        /// <inheritdoc/>
        private void DecodeJson(IDecoder decoder) {
            PayloadType = DiscoveryResponsePayloadType.DataSetMetaData;
            SequenceNumber = decoder.ReadUInt16("SequenceNumber");
            DataSetWriterId = decoder.ReadUInt16("DataSetWriterId");
            MetaData = decoder.ReadEncodeable("DataSetMetaData", typeof(DataSetMetaDataType))
                    as DataSetMetaDataType;
            Status = decoder.ReadStatusCode("StatusCode"); ;
        }
    }
}