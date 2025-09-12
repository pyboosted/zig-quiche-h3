#!/usr/bin/env bun
/**
 * Manual cleanup script for test temporary files
 * Run this to clean up all temporary test files
 */
import { cleanupAll, cleanupOldFiles, getTmpDir } from "./e2e/helpers/testUtils";
import { existsSync, readdirSync, statSync } from "fs";
import { join } from "path";

async function main() {
    const tmpDir = getTmpDir();
    console.log(`📁 Temp directory: ${tmpDir}`);
    
    // Check if directory exists
    if (!existsSync(tmpDir)) {
        console.log("✓ No tmp directory exists - nothing to clean");
        return;
    }
    
    // Count files before cleanup
    const filesBefore = readdirSync(tmpDir);
    let totalSize = 0;
    for (const file of filesBefore) {
        const stats = statSync(join(tmpDir, file));
        totalSize += stats.size;
    }
    
    console.log(`📊 Found ${filesBefore.length} files (${(totalSize / 1024 / 1024).toFixed(2)} MB)`);
    
    // Determine cleanup mode from arguments
    const args = process.argv.slice(2);
    const forceAll = args.includes("--all") || args.includes("-a");
    
    if (forceAll) {
        console.log("🗑️  Cleaning ALL temporary files...");
        await cleanupAll();
        console.log("✓ All temporary files removed");
    } else {
        console.log("🗑️  Cleaning files older than 30 minutes...");
        await cleanupOldFiles(30);
        
        // Count remaining files
        if (existsSync(tmpDir)) {
            const filesAfter = readdirSync(tmpDir);
            const cleaned = filesBefore.length - filesAfter.length;
            console.log(`✓ Cleaned ${cleaned} old files, ${filesAfter.length} recent files kept`);
        } else {
            console.log("✓ All files cleaned (directory removed)");
        }
    }
}

// Run the cleanup
main().catch(console.error);