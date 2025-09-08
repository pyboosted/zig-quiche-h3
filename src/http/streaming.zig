const std = @import("std");
const quiche = @import("quiche");

/// Configuration for streaming operations
pub const StreamingConfig = struct {
    chunk_size: usize = 64 * 1024,      // 64KB chunks
    max_body_buffer: usize = 10 * 1024 * 1024, // 10MB max buffer
    read_buffer_size: usize = 128 * 1024,  // 128KB read buffer
};

/// Tracks partial response state for resumable sends
pub const PartialResponse = struct {
    body_source: BodySource,        // Where data comes from
    written: usize,                 // Bytes written so far
    total_size: ?usize,            // Total size if known
    fin_on_complete: bool,          // Send FIN when done
    allocator: std.mem.Allocator,   // For cleanup
    config: StreamingConfig,        // Streaming configuration
    
    pub const BodySource = union(enum) {
        memory: MemorySource,        // External memory reference
        file: FileSource,           // File streaming
        generator: GeneratorSource,  // Dynamic generation
    };
    
    pub const MemorySource = struct {
        data: []const u8,           // External slice (not owned)
    };
    
    pub const FileSource = struct {
        file: std.fs.File,          // Owned file handle
        buffer: []u8,               // Owned read buffer
        offset: usize,              // Current file read position
        buf_len: usize,             // Valid data length in buffer
        buf_sent: usize,            // Bytes sent from current buffer
    };
    
    pub const GeneratorSource = struct {
        context: *anyopaque,
        generateFn: *const fn(ctx: *anyopaque, buf: []u8) anyerror!usize,
        buffer: []u8,               // Owned reusable buffer
        gen_len: usize,             // Valid data length in buffer
        gen_sent: usize,            // Bytes sent from current buffer
        done: bool,
    };
    
    /// Initialize a partial response for memory
    pub fn initMemory(
        allocator: std.mem.Allocator,
        data: []const u8,
        fin_on_complete: bool,
    ) !*PartialResponse {
        const self = try allocator.create(PartialResponse);
        self.* = .{
            .body_source = .{ .memory = .{ .data = data } },
            .written = 0,
            .total_size = data.len,
            .fin_on_complete = fin_on_complete,
            .allocator = allocator,
            .config = .{}, // Use default config
        };
        return self;
    }
    
    /// Initialize a partial response for file
    pub fn initFile(
        allocator: std.mem.Allocator,
        file: std.fs.File,
        file_size: usize,
        buffer_size: usize,
        fin_on_complete: bool,
    ) !*PartialResponse {
        const buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(buffer);
        
        const self = try allocator.create(PartialResponse);
        self.* = .{
            .body_source = .{ .file = .{
                .file = file,
                .buffer = buffer,
                .offset = 0,
                .buf_len = 0,
                .buf_sent = 0,
            }},
            .written = 0,
            .total_size = file_size,
            .fin_on_complete = fin_on_complete,
            .allocator = allocator,
            .config = .{}, // Use default config
        };
        return self;
    }
    
    /// Initialize a partial response for generator
    pub fn initGenerator(
        allocator: std.mem.Allocator,
        context: *anyopaque,
        generateFn: *const fn(ctx: *anyopaque, buf: []u8) anyerror!usize,
        buffer_size: usize,
        total_size: ?usize,
        fin_on_complete: bool,
    ) !*PartialResponse {
        const buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(buffer);
        
        const self = try allocator.create(PartialResponse);
        self.* = .{
            .body_source = .{ .generator = .{
                .context = context,
                .generateFn = generateFn,
                .buffer = buffer,
                .gen_len = 0,
                .gen_sent = 0,
                .done = false,
            }},
            .written = 0,
            .total_size = total_size,
            .fin_on_complete = fin_on_complete,
            .allocator = allocator,
            .config = .{}, // Use default config
        };
        return self;
    }
    
    /// Clean up resources
    pub fn deinit(self: *PartialResponse) void {
        switch (self.body_source) {
            .memory => {
                // Memory is external, don't free
            },
            .file => |*f| {
                f.file.close();
                self.allocator.free(f.buffer);
            },
            .generator => |*g| {
                self.allocator.free(g.buffer);
            },
        }
        self.allocator.destroy(self);
    }
    
    /// Get the next chunk to send
    pub fn getNextChunk(self: *PartialResponse) !struct { data: []const u8, is_final: bool } {
        switch (self.body_source) {
            .memory => |*m| {
                const remaining = m.data[self.written..];
                // Cap chunk size for memory sources to smooth pacing
                const chunk_size = @min(remaining.len, self.config.chunk_size);
                const chunk = remaining[0..chunk_size];
                const is_final = chunk.len == 0;
                return .{ .data = chunk, .is_final = is_final };
            },
            .file => |*f| {
                // Return unsent portion of current buffer if any
                if (f.buf_sent < f.buf_len) {
                    const remaining = f.buffer[f.buf_sent..f.buf_len];
                    return .{ .data = remaining, .is_final = false };
                }
                
                // Buffer fully sent, read next chunk
                const read = try f.file.pread(f.buffer, f.offset);
                if (read == 0) {
                    return .{ .data = "", .is_final = true };
                }
                
                // Update buffer state
                f.buf_len = read;
                f.buf_sent = 0;
                f.offset += read;
                
                const is_final = (self.total_size != null and f.offset >= self.total_size.?);
                return .{ .data = f.buffer[0..read], .is_final = is_final };
            },
            .generator => |*g| {
                if (g.done) {
                    return .{ .data = "", .is_final = true };
                }
                
                // Return unsent portion of current buffer if any
                if (g.gen_sent < g.gen_len) {
                    const remaining = g.buffer[g.gen_sent..g.gen_len];
                    return .{ .data = remaining, .is_final = false };
                }
                
                // Buffer fully sent, generate next chunk
                const generated = try g.generateFn(g.context, g.buffer);
                if (generated == 0) {
                    g.done = true;
                    return .{ .data = "", .is_final = true };
                }
                
                // Update buffer state
                g.gen_len = generated;
                g.gen_sent = 0;
                
                const is_final = false; // Generator decides when done
                return .{ .data = g.buffer[0..generated], .is_final = is_final };
            },
        }
    }
    
    /// Update written count after successful send
    pub fn updateWritten(self: *PartialResponse, bytes: usize) void {
        self.written += bytes;
        
        // Update source-specific sent counters
        switch (self.body_source) {
            .memory => {},
            .file => |*f| {
                f.buf_sent += bytes;
            },
            .generator => |*g| {
                g.gen_sent += bytes;
            },
        }
    }
    
    /// Check if complete
    pub fn isComplete(self: *const PartialResponse) bool {
        if (self.total_size) |total| {
            return self.written >= total;
        }
        
        // For generators without known size, check done flag
        if (self.body_source == .generator) {
            return self.body_source.generator.done;
        }
        
        return false;
    }
};

/// Tracks blocked streams waiting for capacity
pub const BlockedStreams = struct {
    queue: std.ArrayList(u64),
    retry_set: std.AutoHashMap(u64, void),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BlockedStreams {
        return .{
            .queue = std.ArrayList(u64){},
            .retry_set = std.AutoHashMap(u64, void).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *BlockedStreams) void {
        self.queue.deinit(self.allocator);
        self.retry_set.deinit();
    }
    
    pub fn addBlocked(self: *BlockedStreams, stream_id: u64) !void {
        if (!self.retry_set.contains(stream_id)) {
            try self.queue.append(self.allocator, stream_id);
            try self.retry_set.put(stream_id, {});
        }
    }
    
    pub fn removeBlocked(self: *BlockedStreams, stream_id: u64) void {
        _ = self.retry_set.remove(stream_id);
        // Don't remove from queue - let it be skipped during iteration
    }
    
    pub fn isBlocked(self: *const BlockedStreams, stream_id: u64) bool {
        return self.retry_set.contains(stream_id);
    }
    
    pub fn clear(self: *BlockedStreams) void {
        self.queue.clearRetainingCapacity();
        self.retry_set.clearRetainingCapacity();
    }
};