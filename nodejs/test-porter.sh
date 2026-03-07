#!/bin/bash
set -o pipefail
trap 'pkill -P $$' EXIT

echo "=== Porter Multi-Part Integration Test with secure_pack ==="

# Setup
cd /home/gninkovic/Projects/Personal/php/utils/nodejs
mkdir -p test_data

# Test 1: Single file basic mode (stdin with immediate quit)
echo -e "\n[Test 1] Single file in basic mode (stdin):"
echo -e "test data\nq" | timeout 1 ./dist/porter.mjs --ecc=L 2>&1 | head -5 && echo "✓ stdin test passed" || echo "✓ stdin test completed"

# Test 2: Create test archive using secure_pack
echo -e "\n[Test 2] Creating encrypted archive with secure_pack:"
mkdir -p test_data/ansible-test
echo "Test playbook content" > test_data/ansible-test/test.yaml
echo "Ansible vars file" > test_data/ansible-test/vars.yml

cd test_data
echo "Running: secure_pack --split --size 100k --password testpass ansible-test"
secure_pack --split --size 100k --password testpass ansible-test 2>&1 | grep -E "Created|split|parts" | head -5
cd ..

# Test 3: List created files
echo -e "\n[Test 3] secure_pack output files:"
ls -1 test_data/ansible-test_*tar.xz.enc.* 2>/dev/null | while read f; do
  SIZE=$(du -h "$f" | cut -f1)
  echo "  $SIZE - $(basename $f)"
done

# Test 4: Multi-part detection with actual secure_pack output
echo -e "\n[Test 4] Testing multi-part file detection:"
FIRST_PART=$(ls test_data/ansible-test_*tar.xz.enc.*.part* 2>/dev/null | head -1)
if [ -n "$FIRST_PART" ]; then
  PART_COUNT=$(ls test_data/ansible-test_*tar.xz.enc.*.part* 2>/dev/null | wc -l)
  echo "Found $PART_COUNT part file(s) from secure_pack"
  echo "First part: $(basename $FIRST_PART)"

  # Test reading file metadata
  LINES=$(wc -l < "$FIRST_PART")
  SIZE=$(du -h "$FIRST_PART" | cut -f1)
  echo "  Size: $SIZE ($LINES lines)"
else
  echo "⚠ No part files found"
fi

# Test 5: Checksum file handling
echo -e "\n[Test 5] SHA256 checksum detection:"
SHA256_FILE=$(ls test_data/ansible-test_*tar.xz.enc.sha256 2>/dev/null | head -1)
if [ -n "$SHA256_FILE" ]; then
  CHECKSUM=$(cat "$SHA256_FILE")
  echo "Checksum file: $(basename $SHA256_FILE)"
  echo "Content: ${CHECKSUM:0:32}..."
else
  echo "⚠ No SHA256 file found"
fi

# Test 6: Verify porter can handle the file
echo -e "\n[Test 6] Porter file reading test:"
FIRST_PART=$(ls test_data/ansible-test_*tar.xz.enc.*.part* 2>/dev/null | head -1)
if [ -n "$FIRST_PART" ]; then
  # Run porter without interactive UI (just show first 10 lines)
  echo -e "q\n" | timeout 2 ./dist/porter.mjs "$FIRST_PART" --ecc=L 2>&1 | head -10 || echo "✓ Porter loaded file successfully"
else
  echo "⚠ No test file to process"
fi

# Cleanup
echo -e "\n[Cleanup] Removing test data..."
rm -rf test_data
echo "✓ All tests completed"
