// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Opc.Ua.PubSub {
    using Opc.Ua.Encoders;
    using System;

    /// <summary>
    /// Data set message
    /// </summary>
    public class DataSetMessagePubSub : IEncodeable {

        /// <summary>
        /// Content mask
        /// </summary>
        public uint MessageContentMask { get; set; }

        /// <summary>
        /// PublisherId
        /// </summary>
        public string PublisherId { get; set; }
        
        /// <summary>
        /// Dataset writer id
        /// </summary>
        public ushort DataSetWriterId { get; set; }

        /// <summary>
        /// Sequence number
        /// </summary>
        public uint SequenceNumber { get; set; }

        /// <summary>
        /// Metadata version
        /// </summary>
        public ConfigurationVersionDataType MetaDataVersion { get; set; }

        /// <summary>
        /// Timestamp
        /// </summary>
        public DateTime Timestamp { get; set; }

        /// <summary>
        /// Picoseconds
        /// </summary>
        public uint Picoseconds { get; set; }

        /// <summary>
        /// Status
        /// </summary>
        public StatusCode Status { get; set; }

        /// <summary>
        /// Payload
        /// </summary>
        public DataSet Payload { get; set; }

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
        public void Decode(IDecoder decoder, MetadataContext metadataContext = null) {
            switch (decoder.EncodingType) {
                case EncodingType.Binary:
                    DecodeBinary(decoder, metadataContext);
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
            ApplyEncodeMask();
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
            if (!Utils.IsEqual(wrapper.MessageContentMask, MessageContentMask) ||
                !Utils.IsEqual(wrapper.DataSetWriterId, DataSetWriterId) ||
                !Utils.IsEqual(wrapper.MetaDataVersion, MetaDataVersion) ||
                !Utils.IsEqual(wrapper.SequenceNumber, SequenceNumber) ||
                !Utils.IsEqual(wrapper.Status, Status) ||
                !Utils.IsEqual(wrapper.Timestamp, Timestamp) ||
                !Utils.IsEqual(wrapper.Payload, Payload) ||
                !Utils.IsEqual(wrapper.BinaryEncodingId, BinaryEncodingId) ||
                !Utils.IsEqual(wrapper.TypeId, TypeId) ||
                !Utils.IsEqual(wrapper.XmlEncodingId, XmlEncodingId)) {
                return false;
            }
            return true;
        }

        /// <inheritdoc/>
        private void ApplyEncodeMask() {
            if (Payload == null) {
                return;
            }
            foreach (var value in Payload.Values) {
                if (value == null) {
                    continue;
                }
                if ((Payload.FieldContentMask & (uint)DataSetFieldContentMask.RawData) != 0 ||
                    (Payload.FieldContentMask & (uint)DataSetFieldContentMask.StatusCode) == 0) {
                    value.StatusCode = StatusCodes.Good;
                }
                if ((Payload.FieldContentMask & (uint)DataSetFieldContentMask.RawData) != 0 ||
                    (Payload.FieldContentMask & (uint)DataSetFieldContentMask.SourceTimestamp) == 0) {
                    value.SourceTimestamp = DateTime.MinValue;
                }
                if ((Payload.FieldContentMask & (uint)DataSetFieldContentMask.RawData) != 0 ||
                    (Payload.FieldContentMask & (uint)DataSetFieldContentMask.ServerTimestamp) == 0) {
                    value.ServerTimestamp = DateTime.MinValue;
                }
                if ((Payload.FieldContentMask & (uint)DataSetFieldContentMask.RawData) != 0 ||
                    (Payload.FieldContentMask & (uint)DataSetFieldContentMask.SourcePicoSeconds) == 0) {
                    value.SourcePicoseconds = 0;
                }
                if ((Payload.FieldContentMask & (uint)DataSetFieldContentMask.RawData) != 0 ||
                    (Payload.FieldContentMask & (uint)DataSetFieldContentMask.ServerPicoSeconds) == 0) {
                    value.ServerPicoseconds = 0;
                }
            }
        }

        /// <inheritdoc/>
        private void EncodeBinary(IEncoder encoder) {
            encoder.WriteUInt32(nameof(MessageContentMask), MessageContentMask);
            encoder.WriteUInt16(nameof(DataSetWriterId), DataSetWriterId);
            if ((MessageContentMask & (uint)UadpDataSetMessageContentMask.SequenceNumber) != 0) {
                encoder.WriteUInt32(nameof(UadpDataSetMessageContentMask.SequenceNumber), SequenceNumber);
            }
            if ((MessageContentMask & (uint)UadpDataSetMessageContentMask.MajorVersion) != 0){ 
                encoder.WriteUInt32(nameof(UadpDataSetMessageContentMask.MajorVersion), MetaDataVersion.MajorVersion);
            }
            if ((MessageContentMask & (uint)UadpDataSetMessageContentMask.MinorVersion) != 0) {
                encoder.WriteUInt32(nameof(UadpDataSetMessageContentMask.MinorVersion), MetaDataVersion.MinorVersion);
            }
            if ((MessageContentMask & (uint)UadpDataSetMessageContentMask.Timestamp) != 0) {
                encoder.WriteDateTime(nameof(UadpDataSetMessageContentMask.Timestamp), Timestamp);
            }
            if ((MessageContentMask & (uint)UadpDataSetMessageContentMask.PicoSeconds) != 0) {
                encoder.WriteUInt32(nameof(UadpDataSetMessageContentMask.PicoSeconds), Picoseconds);
            }
            if ((MessageContentMask & (uint)UadpDataSetMessageContentMask.Status) != 0) {
                encoder.WriteStatusCode(nameof(Status), Status);
            }
            if (Payload != null) {
                var payload = new KeyDataValuePairCollection();
                foreach (var tuple in Payload) {
                    payload.Add(new KeyDataValuePair() {
                        Key = tuple.Key,
                        Value = tuple.Value
                    });
                }
                encoder.WriteEncodeableArray(nameof(Payload), payload.ToArray(), typeof(KeyDataValuePair));
            }

        }

        /// <inheritdoc/>
        private void EncodeJson(IEncoder encoder) {
            if ((MessageContentMask & (uint)JsonDataSetMessageContentMask.DataSetWriterId) != 0) {
                encoder.WriteString(nameof(JsonDataSetMessageContentMask.DataSetWriterId), DataSetWriterId.ToString());
            }
            if ((MessageContentMask & (uint)JsonDataSetMessageContentMask.SequenceNumber) != 0) {
                encoder.WriteUInt32(nameof(JsonDataSetMessageContentMask.SequenceNumber), SequenceNumber);
            }
            if ((MessageContentMask & (uint)JsonDataSetMessageContentMask.MetaDataVersion) != 0) {
                encoder.WriteEncodeable(nameof(JsonDataSetMessageContentMask.MetaDataVersion), MetaDataVersion, typeof(ConfigurationVersionDataType));
            }
            if ((MessageContentMask & (uint)JsonDataSetMessageContentMask.Timestamp) != 0) {
                encoder.WriteDateTime(nameof(JsonDataSetMessageContentMask.Timestamp), Timestamp);
            }
            if ((MessageContentMask & (uint)JsonDataSetMessageContentMask.Status) != 0) {
                encoder.WriteStatusCode(nameof(JsonDataSetMessageContentMask.Status), Status);
            }
            if (Payload != null) {
                var jsonEncoder = encoder as JsonEncoderEx;
                jsonEncoder.WriteDataValueDictionary(nameof(Payload), Payload);
            }
        }

        /// <inheritdoc/>
        private void DecodeBinary(IDecoder decoder, MetadataContext metadataContext = null) {

            var dataSetFlags1 = decoder.ReadByte("DataSetFlags1");
            var isDataSetMessageValid = (dataSetFlags1 & 0x01) != 0;
            if (!isDataSetMessageValid) {
                // message is invalid, to be dropped
                throw new Exception("Invalid message");
            }
            var fieldEncoding = dataSetFlags1 >> 1 & 0x03;
            var isSequenceNumberEnabled = (dataSetFlags1 & 0x08) != 0 ;
            var isStatusEnabled = (dataSetFlags1 & 0x10) != 0;
            var isConfigurationMajorVersionEnabled = (dataSetFlags1 & 0x20) != 0;
            var isConfigurationMinorVersionEnabled = (dataSetFlags1 & 0x40) != 0;
            var isDataSetFlags2Enabled = (dataSetFlags1 & 0x80) != 0;

            var dataSetFlags2 = isDataSetFlags2Enabled ? decoder.ReadByte("DataSetFlags2") : (byte)0;
            var dataSetMessageType = dataSetFlags2 & 0x0f;
            // todo 
            var isTimestampEnabled = (dataSetFlags2 & 0x10) != 0;
            var isPicoSecondsEnabled = (dataSetFlags2 & 0x20) != 0;

            SequenceNumber = isSequenceNumberEnabled ?
                decoder.ReadUInt16("DataSetMessageSequenceNumber") : (ushort)0;
            Timestamp = isTimestampEnabled ?
                decoder.ReadDateTime("Timestamp") : DateTime.MinValue;
            Picoseconds = isPicoSecondsEnabled ? decoder.ReadUInt16("PicoSeconds") : (ushort)0;
            Status = isStatusEnabled ? decoder.ReadStatusCode("Status") : StatusCodes.Good;
            var configurationMajorVersion = isConfigurationMajorVersionEnabled ?
                decoder.ReadUInt32("ConfigurationMajorVersion") : 0;
            var configurationMinorVersion = isConfigurationMinorVersionEnabled ?
                decoder.ReadUInt32("ConfigurationMinorVersion") : 0;

            MetaDataVersion = new ConfigurationVersionDataType() {
                MajorVersion = configurationMajorVersion,
                MinorVersion = configurationMinorVersion
            };

            switch (dataSetMessageType) {
                case 0: // DataKeyFrame
                    switch (fieldEncoding) {
                        case 0: // Variant
                            Payload = new DataSet();
                            var fieldCount = decoder.ReadUInt16("FieldCount");
                            for (var index = 0; index < fieldCount; index++) {
                                var dataValue = new DataValue();
                                dataValue.Value = decoder.ReadVariant("DataSetField");
                                // TODO check if bad/uncertain status code 
                                Payload[index.ToString()] = dataValue;
                            }
                            break;
                        case 1: // RawData
                            if (metadataContext == null) {
                                throw new Exception("MetadataContext not provided for decoding raw data");
                            }
                            var metaDataType = metadataContext.GetDataSetMetaDataType(PublisherId, DataSetWriterId,
                                MetaDataVersion?.MajorVersion, MetaDataVersion.MinorVersion);
                            if (metaDataType == null) {
                                throw new Exception("MetaData not available for decoding raw data");
                            }

                            fieldCount = decoder.ReadUInt16("FieldCount");
                            if (fieldCount != metaDataType.Fields.Count) {
                                throw new Exception("Field count missmatch");
                            }

                            Payload = new DataSet();
                            foreach (var field in metaDataType.Fields) {
                                var builtinType = DataTypes.GetBuiltInType(field.BuiltInType);
                                var systemType = DataTypes.GetSystemType(field.DataType, decoder.Context.Factory);
                                
                                var value = decoder.ReadEncodeable("DataSetField", systemType);
                                var dataValue = new DataValue();
                                dataValue.Value = value;
                                Payload[field.Name] = dataValue;
                            }
                            break;
                        case 2: // DataValue
                            Payload = new DataSet();
                            fieldCount = decoder.ReadByte("FieldCount");
                            for (var index = 0; index < fieldCount; index++) {
                                Payload[index.ToString()] = decoder.ReadDataValue("DataSetField");
                            }
                            break;
                        default:
                            throw new Exception("Invalid field encoding");
                    }
                    break;

                case 1: // DeltaFrame
                    switch (fieldEncoding) {
                        case 0: // Variant
                            Payload = new DataSet();
                            var fieldCount = decoder.ReadUInt16("FieldCount");
                            for (var index = 0; index < fieldCount; index++) {
                                var dataFieldIndex = decoder.ReadUInt16("Index");
                                var dataValue = new DataValue();
                                dataValue.Value = decoder.ReadVariant("DataSetField");
                                // TODO check if bad/ uncertain status code 
                                Payload[dataFieldIndex.ToString()] = dataValue;
                            }
                            break;
                        case 1: // RawData

                            if (metadataContext == null) {
                                throw new Exception("MetadataContext not provided for decoding raw data");
                            }
                            var metaDataType = metadataContext.GetDataSetMetaDataType(PublisherId, DataSetWriterId, 
                                MetaDataVersion?.MajorVersion, MetaDataVersion.MinorVersion);
                            if (metaDataType == null) {
                                throw new Exception("MetaData not available for decoding raw data");
                            }

                            fieldCount = decoder.ReadUInt16("FieldCount");

                            Payload = new DataSet();
                            for  (var currentField = 0; currentField < fieldCount; currentField++) {
                                var fieldIndex = decoder.ReadUInt16("Index");
                                var field = metaDataType.Fields[fieldIndex];
                                var builtinType = DataTypes.GetBuiltInType(field.BuiltInType);
                                var systemType = DataTypes.GetSystemType(field.DataType, decoder.Context.Factory);
                                var value = decoder.ReadEncodeable("DataSetField", systemType);
                                var dataValue = new DataValue();
                                dataValue.Value = value;
                                Payload[field.Name] = dataValue;
                            }
                            break;
                        case 2: // DataValue
                            Payload = new DataSet();
                            fieldCount = decoder.ReadUInt16("FieldCount");
                            for (var index = 0; index < fieldCount; index++) {
                                var dataFieldIndex = decoder.ReadUInt16("Index");
                                Payload[dataFieldIndex.ToString()] = decoder.ReadDataValue("DataSetField");
                            }
                            break;
                        default:
                            throw new Exception("Invalid field encoding");
                    }
                    break;

                case 2: // Event
                    switch (fieldEncoding) {
                        case 0: // Variant
                            var fieldCount = decoder.ReadUInt16("FieldCount");
                            for (var index = 0; index < fieldCount; index++) {
                                var dataValue = new DataValue();
                                dataValue.Value = decoder.ReadVariant("DataSetField");
                                // TODO check if bad/ uncertain status code 
                                Payload[index.ToString()] = dataValue;
                            }
                            break;
                        default:
                            throw new Exception("Invalid field encoding");
                    }
                    break;

                case 3: // KeepAlive
                    throw new Exception("KeepAlive DataSetMssageType not supported");
                default:
                    throw new Exception("Invalid DataSetMessageType");
            }
        }

        /// <inheritdoc/>
        private void DecodeJson(IDecoder decoder) {
            DataSetWriterId = decoder.ReadUInt16(nameof(JsonDataSetMessageContentMask.DataSetWriterId));
            if (DataSetWriterId != 0) {
                MessageContentMask |= (uint)JsonDataSetMessageContentMask.DataSetWriterId;
            }
            SequenceNumber = decoder.ReadUInt32(nameof(JsonDataSetMessageContentMask.SequenceNumber));
            if (SequenceNumber != 0) {
                MessageContentMask |= (uint)JsonDataSetMessageContentMask.SequenceNumber;
            }
            MetaDataVersion = decoder.ReadEncodeable(
                nameof(JsonDataSetMessageContentMask.MetaDataVersion), typeof(ConfigurationVersionDataType))
                as ConfigurationVersionDataType;
            if (MetaDataVersion != null) {
                MessageContentMask |= (uint)JsonDataSetMessageContentMask.MetaDataVersion;
            }
            Timestamp = decoder.ReadDateTime(nameof(JsonDataSetMessageContentMask.Timestamp));
            if (Timestamp != null) {
                MessageContentMask |= (uint)JsonDataSetMessageContentMask.Timestamp;
            }
            Status = decoder.ReadStatusCode(nameof(JsonDataSetMessageContentMask.Status));
            if (Status != null) {
                MessageContentMask |= (uint)JsonDataSetMessageContentMask.Status;
            }

            var jsonDecoder = decoder as JsonDecoderEx;
            var payload = jsonDecoder.ReadDataValueDictionary(nameof(Payload));
            Payload = new DataSet(payload, 0);
        }
    }
}