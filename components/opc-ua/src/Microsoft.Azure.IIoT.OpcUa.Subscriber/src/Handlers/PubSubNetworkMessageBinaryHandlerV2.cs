// ------------------------------------------------------------
//  Copyright (c) Microsoft Corporation.  All rights reserved.
//  Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

namespace Microsoft.Azure.IIoT.OpcUa.Subscriber.Handlers {
    using Microsoft.Azure.IIoT.OpcUa.Subscriber;
    using Microsoft.Azure.IIoT.OpcUa.Subscriber.Models;
    using Microsoft.Azure.IIoT.OpcUa.Protocol;
    using Microsoft.Azure.IIoT.Hub;
    using Opc.Ua;
    using Opc.Ua.PubSub;
    using Opc.Ua.Client.ComplexTypes;
    using Serilog;
    using System;
    using System.IO;
    using System.Collections.Generic;
    using System.Linq;
    using System.Threading.Tasks;

    /// <summary>
    /// Publisher message handling
    /// </summary>
    public sealed class PubSubNetworkMessageBinaryHandlerV2 : IDeviceTelemetryHandler {

        /// <inheritdoc/>
        public string MessageSchema => Core.MessageSchemaTypes.NetworkMessageUadpV2;

        /// <summary>
        /// Create handler
        /// </summary>
        /// <param name="encoder"></param>
        /// <param name="handlers"></param>
        /// <param name="logger"></param>
        public PubSubNetworkMessageBinaryHandlerV2(IVariantEncoderFactory encoder,
            IEnumerable<ISubscriberMessageProcessor> handlers, ILogger logger) {
            _encoder = encoder ?? throw new ArgumentNullException(nameof(encoder));
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
            _handlers = handlers?.ToList() ?? throw new ArgumentNullException(nameof(handlers));
            _context = new ServiceMessageContext();
            _metadataContext = new MetadataContext();
            _chunks = new Dictionary<Tuple<string, ushort>, NetworkMessagePubSub>();

        }

    /// <inheritdoc/>
    public async Task HandleAsync(string deviceId, string moduleId,
            byte[] payload, IDictionary<string, string> properties, Func<Task> checkpoint) {

            try {
                var decoder = new BinaryDecoder(new MemoryStream(payload), _context);
                var message = new NetworkMessagePubSub();
                message.Decode(decoder, _metadataContext);
                var publisherId = message.PublisherId;
                if (message.Chunks != null) {
                    var id = new Tuple<string, ushort>(message.PublisherId, message.Chunks.First().DataSetWriterId);
                    if (_chunks.TryGetValue(id, out var chunk) && chunk != null) {
                        if (chunk.Chunks.First()?.MessageSequenceNumber ==
                            message.Chunks.First()?.MessageSequenceNumber) {
                            _chunks[id].Chunks.AddRange(message.Chunks);
                        }
                        else {
                            // drop the old partialy procesed chunk
                            _chunks[id] = message;
                        }
                    }
                    else {
                        _chunks[id] = message;
                    }

                    // handle the 
                    var complete = true;
                    var totalSize = (uint)0;
                    var orderedChunks = _chunks[id].Chunks.OrderBy(c => c.ChunkOffset).ToArray();
                    for (var index = 0; index < orderedChunks.Length; index++) {
                        if (orderedChunks[index].ChunkOffset + orderedChunks[index].ChunkData.Length !=
                            ((index < orderedChunks.Length - 1) ? orderedChunks[index + 1].ChunkOffset : orderedChunks[index].TotalSize)) {
                            complete = false;
                        }
                        else {
                            totalSize += orderedChunks[index].ChunkOffset + (uint)orderedChunks[index].ChunkData.Length;
                        }
                    }
                    if (!complete) {
                        return;
                    }
                    try {
                        var aggregatedChunks = new byte[totalSize];
                        for (var index = 0; index < orderedChunks.Length; index++) {
                            orderedChunks[index].ChunkData.CopyTo(aggregatedChunks, orderedChunks[index].ChunkOffset);
                        }
                        var payloadDecoder = new BinaryDecoder(new MemoryStream(aggregatedChunks), _context);
                        switch (message.MessageType) {
                            case NetworkMessageType.DataSetMessagePayload:
                                if (message.PayloadHeader.Count > 1) {
                                    var messageSizes = new ushort[message.PayloadHeader.Count];
                                    for (var index = 0; index < message.PayloadHeader.Count; index++) {
                                        messageSizes[index] = payloadDecoder.ReadUInt16("Sizes");
                                    }
                                }
                                message.Messages = new List<DataSetMessagePubSub>();
                                for (var index = 0; index < message.PayloadHeader.Count; index++) {
                                    var dataSetMessage = new DataSetMessagePubSub();
                                    dataSetMessage.PublisherId = publisherId;
                                    dataSetMessage.DataSetWriterId = message.PayloadHeader[index];
                                    dataSetMessage.Decode(payloadDecoder, _metadataContext);
                                    message.Messages.Add(dataSetMessage);
                                }
                                break;
                            case NetworkMessageType.DiscoveryRequestPayload:
                                throw new NotImplementedException("DiscoveryRequestPayload not implemented.");
                            case NetworkMessageType.DiscoveryResponsePayload: // discovery response 
                                message.DiscoveryResponsePayload = payloadDecoder.ReadEncodeable("DiscoveryResponsePayload",
                                    typeof(DiscoveryResponsePayload)) as DiscoveryResponsePayload;
                                break;
                            default:
                                throw new Exception("Invalid message network type.");
                        }
                    }
                    catch (Exception ex) {
                        _logger.Error(ex, "Subscriber binary network message handling failed - skip");
                    }

                    finally {
                        _chunks[id] = null;
                    }
                }

                switch (message.MessageType) {
                    case NetworkMessageType.DataSetMessagePayload:
                        break;
                    case NetworkMessageType.DiscoveryResponsePayload:
                        _metadataContext.AddOrUpdateDataSetMetaDataType(message);

                        foreach (var newType in message.DiscoveryResponsePayload.MetaData.StructureDataTypes) {
                            var complexTypeBuilder = new ComplexTypeBuilder(
                                new AssemblyModule(),
                                message.DiscoveryResponsePayload.MetaData.Namespaces[
                                    newType.DataTypeId.NamespaceIndex],
                                    newType.DataTypeId.NamespaceIndex
                                );
                            var fieldBuilder = complexTypeBuilder.AddStructuredType(newType.Name, newType.StructureDefinition);
                            fieldBuilder.AddTypeIdAttribute(newType.DataTypeId, newType.BinaryEncodingId, newType.XmlEncodingId);

                            var index = 1;
                            foreach (var field in newType.StructureDefinition.Fields) {
                                Type fieldType = TypeInfo.GetSystemType(field.DataType, null);
                                field.IsOptional = newType.StructureDefinition.StructureType == StructureType.StructureWithOptionalFields;
                                fieldBuilder.AddField(field, fieldType, index++);
                            }
                            var complexType = fieldBuilder.CreateType();
                            if (_context != null) {
                                _context.Factory.AddEncodeableType(newType.DataTypeId, complexType);
                                _context.Factory.AddEncodeableType(newType.BinaryEncodingId, complexType);
                                _context.Factory.AddEncodeableType(newType.XmlEncodingId, complexType);
                            }
                        }


                        return;
                }

                foreach (var dataSetMessage in message.Messages) {
                    var dataset = new DataSetMessageModel {
                        PublisherId = message.PublisherId,
                        MessageId = message.MessageId,
                        DataSetClassId = message.DataSetClassId,
                        DataSetWriterId = dataSetMessage.DataSetWriterId.ToString(),
                        SequenceNumber = dataSetMessage.SequenceNumber,
                        Status = StatusCode.LookupSymbolicId(dataSetMessage.Status.Code),
                        MetaDataVersion = $"{dataSetMessage.MetaDataVersion.MajorVersion}" +
                            $".{dataSetMessage.MetaDataVersion.MinorVersion}",
                        Timestamp = dataSetMessage.Timestamp,
                        Payload = new Dictionary<string, DataValueModel>()
                    };

                    if (dataSetMessage.Payload != null) {
                        foreach (var datapoint in dataSetMessage.Payload) {
                            var codec = _encoder.Create(_context);
                            var type = BuiltInType.Null;
                            dataset.Payload[datapoint.Key] = new DataValueModel {
                                Value = datapoint.Value == null
                                    ? null : codec.Encode(datapoint.Value.WrappedValue, out type),
                                DataType = type == BuiltInType.Null
                                    ? null : type.ToString(),
                                Status = (datapoint.Value?.StatusCode.Code == StatusCodes.Good)
                                    ? null : StatusCode.LookupSymbolicId(datapoint.Value.StatusCode.Code),
                                SourceTimestamp = (datapoint.Value?.SourceTimestamp == DateTime.MinValue)
                                    ? null : datapoint.Value?.SourceTimestamp,
                                SourcePicoseconds = (datapoint.Value?.SourcePicoseconds == 0)
                                    ? null : datapoint.Value?.SourcePicoseconds,
                                ServerTimestamp = (datapoint.Value?.ServerTimestamp == DateTime.MinValue)
                                    ? null : datapoint.Value?.ServerTimestamp,
                                ServerPicoseconds = (datapoint.Value?.ServerPicoseconds == 0)
                                    ? null : datapoint.Value?.ServerPicoseconds
                            };
                        }
                        await Task.WhenAll(_handlers.Select(h => h.HandleMessageAsync(dataset)));
                    }
                    else {
                        _logger.Error("Subscriber binary network message handling failed - skip");
                    }
                }
            }
            catch (Exception ex) {
                _logger.Error(ex, "Subscriber binary network message handling failed - skip");
            }
        }

        /// <inheritdoc/>
        public Task OnBatchCompleteAsync() {
            return Task.CompletedTask;
        }

        private readonly ServiceMessageContext _context;
        private readonly MetadataContext _metadataContext;
        private readonly Dictionary<Tuple<string, ushort>, NetworkMessagePubSub> _chunks;

        private readonly IVariantEncoderFactory _encoder;
        private readonly ILogger _logger;
        private readonly List<ISubscriberMessageProcessor> _handlers;
    }
}
