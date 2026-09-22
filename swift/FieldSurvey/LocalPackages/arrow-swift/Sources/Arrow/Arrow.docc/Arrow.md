<!--
  Licensed to the Apache Software Foundation (ASF) under one
  or more contributor license agreements.  See the NOTICE file
  distributed with this work for additional information
  regarding copyright ownership.  The ASF licenses this file
  to you under the Apache License, Version 2.0 (the
  "License"); you may not use this file except in compliance
  with the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing,
  software distributed under the License is distributed on an
  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
  KIND, either express or implied.  See the License for the
  specific language governing permissions and limitations
  under the License.
-->

# ``Arrow``

Apache Arrow: Columnar format for fast data interchange and in-memory analytics.

## Overview

Arrow provides a universal columnar data format optimized for efficient analytic operations. This Swift implementation enables you to:

- Read and write Arrow IPC file and streaming formats
- Build columnar data structures with typed arrays
- Work with record batches and tables
- Encode and decode Swift types to Arrow format
- Interoperate with other Arrow implementations via the C Data Interface

## Topics

### Reading and Writing Data

- ``ArrowReader``
- ``ArrowWriter``

### Core Data Structures

- ``ArrowTable``
- ``RecordBatch``
- ``ArrowColumn``
- ``ChunkedArray``

### Arrays

- ``ArrowArray``
- ``ArrowArrayBuilder``
- ``ArrowArrayHolder``

### Schema and Types

- ``ArrowSchema``
- ``ArrowField``
- ``ArrowType``

### Encoding and Decoding

- ``ArrowEncoder``
- ``ArrowDecoder``

### C Data Interface

- ``ArrowCExporter``
- ``ArrowCImporter``
