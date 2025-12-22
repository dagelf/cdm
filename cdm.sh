#!/bin/bash

cd "$(dirname "$0")"

BASELINE_FILE="${1:-baseline.json}"
SIZE="${2:-512m}"
OUTPUT_FILE="output.json"
HISTORY_FILE="cdm_history.log"
FIO_FILE="cdm.fio"

# Cleanup trap to remove temporary files on exit or interruption
cleanup() {
    rm -f temp_run_*.json *.tmp
}
trap cleanup EXIT

if [ ! -f "$OUTPUT_FILE" ]; then
    echo "{}" > "$OUTPUT_FILE"
fi

# Robustly extract sections, handling optional whitespace inside brackets
TESTS=$(grep -E '^\s*\[.*\]' "$FIO_FILE" | sed 's/^\s*\[\s*//;s/\s*\]\s*$//' | grep -vE '^(global|x)$')

echo "Tests found in $FIO_FILE:"
echo "$TESTS"
echo "--------------------------------"

# Header for this run session in history
echo "" >> "$HISTORY_FILE"
echo "--- Run Date: $(date) ---" >> "$HISTORY_FILE"

for TEST_NAME in $TESTS; do
    EXISTS=$(jq --arg name "$TEST_NAME" '.jobs[]? | select(.jobname == $name) | .jobname' "$OUTPUT_FILE")

    if [ -z "$EXISTS" ]; then
#        echo "Running missing test: $TEST_NAME with size $SIZE"
        TEMP_OUTPUT="temp_run_${TEST_NAME}.json"
        
        # Added --quiet to suppress stdout noise
        if fio --section="$TEST_NAME" --size="$SIZE" --output-format=json --output="$TEMP_OUTPUT" "$FIO_FILE"; then
            
            # Clean potential garbage at start of file (fio sometimes outputs text before json)
            # Only proceed if file exists and has content
            if [ -s "$TEMP_OUTPUT" ]; then
                sed -n '/^{/,$p' "$TEMP_OUTPUT" > "${TEMP_OUTPUT}.tmp" && mv "${TEMP_OUTPUT}.tmp" "$TEMP_OUTPUT"
                
                # Format and display output
                STATS=$(jq -r '
                    def lpad($str; $len): ("                    " + ($str|tostring)) | .[-$len:];
                    def rpad($str; $len): (($str|tostring) + "                    " + "          ") | .[0:$len];
                    
                    def fmt_val($val):
                        if $val then ($val | round | tostring) else "N/A" end | lpad(.; 15);

                    .jobs[0] | 
                    (.jobname) as $jobname |
                    (.read.bw / 1024) as $rbw |
                    (.write.bw / 1024) as $wbw |
                    (.read.iops) as $riops |
                    (.write.iops) as $wiops |
                    (.read.lat_ns.mean / 1000) as $rlat |
                    (.write.lat_ns.mean / 1000) as $wlat |
                    
                    "\(rpad($jobname; 25))\t\(fmt_val($rbw))\t\(fmt_val($wbw))\t\(fmt_val($riops))\t\(fmt_val($wiops))\t\(fmt_val($rlat))\t\(fmt_val($wlat))"
                ' "$TEMP_OUTPUT" 2>/dev/null)

                if [ $? -eq 0 ] && [ ! -z "$STATS" ]; then
                    echo "$STATS"
                    echo "$STATS" >> "$HISTORY_FILE"
                    
                    if [ "$(cat "$OUTPUT_FILE")" == "{}" ]; then
                        mv "$TEMP_OUTPUT" "$OUTPUT_FILE"
                    else
                        jq -s '.[0].jobs += .[1].jobs | .[0]' "$OUTPUT_FILE" "$TEMP_OUTPUT" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
                        rm -f "$TEMP_OUTPUT"
                    fi
                else
                    echo "Error parsing results for $TEST_NAME. Skipping merge."
                    rm -f "$TEMP_OUTPUT"
                fi
            else
                 echo "Error: Output file for $TEST_NAME is empty."
            fi
        else
            echo "Error running fio for $TEST_NAME"
        fi
        
    else
        echo "Test $TEST_NAME already exists in $OUTPUT_FILE. Skipping."
    fi
done

    echo "--------------------------------"

    jq -r -n --slurpfile baseline "$BASELINE_FILE" --slurpfile current "$OUTPUT_FILE" '
        def lpad($str; $len): ("                    " + ($str|tostring)) | .[-$len:];
        def rpad($str; $len): (($str|tostring) + "                    " + "          ") | .[0:$len];
        
        def fmt_val($val):
            if $val then ($val | round | tostring) else "N/A" end | lpad(.; 15);

        def calc_diff($curr; $base):
            if $curr and $base and $base > 0 then
                 (($curr - $base) / $base * 100 | round) as $d |
                 (if $d >= 0 then "+" else "" end) + ($d|tostring) + "%"
            else "-" end;

        (rpad("Test Name"; 25) + "\t" + (["Read MB/s", "Write MB/s", "Read IOPS", "Write IOPS", "Read Lat (us)", "Write Lat (us)", "MB/s Diff", "IOPS Diff", "Lat Diff"] | map(lpad(.; 15)) | join("\t"))),

        ($baseline[0].jobs // []) as $b_jobs |
        $current[0].jobs | 
        map(
           . + { 
             base_name: (.jobname | sub("-(Read|Write)$"; "")),
             type_name: (if .jobname | test("-Read$") then "Read" else "Write" end)
           }
        ) as $jobs |
        
        ($jobs | map(.base_name) | reduce .[] as $n ([]; if .[-1] != $n then . + [$n] else . end)) as $bases |
        
        $bases[] |
        . as $base |
        
        ($jobs | map(select(.base_name == $base))) as $group |
        ( ($group[] | select(.type_name == "Read")) // null ) as $read_job |
        ( ($group[] | select(.type_name == "Write")) // null ) as $write_job |
        
        ($b_jobs | map(select(.jobname == ($base + "-Read"))) | .[0] // null) as $b_read_job |
        ($b_jobs | map(select(.jobname == ($base + "-Write"))) | .[0] // null) as $b_write_job |

        # Metrics (integers)
        ($read_job.read.bw / 1024) as $rbw | ($b_read_job.read.bw / 1024) as $b_rbw |
        ($write_job.write.bw / 1024) as $wbw | ($b_write_job.write.bw / 1024) as $b_wbw |
        ($read_job.read.iops) as $riops | ($b_read_job.read.iops) as $b_riops |
        ($write_job.write.iops) as $wiops | ($b_write_job.write.iops) as $b_wiops |
        ($read_job.read.lat_ns.mean / 1000) as $rlat | ($b_read_job.read.lat_ns.mean / 1000) as $b_rlat |
        ($write_job.write.lat_ns.mean / 1000) as $wlat | ($b_write_job.write.lat_ns.mean / 1000) as $b_wlat |
        
        # Diffs
        "\(calc_diff($rbw; $b_rbw)) / \(calc_diff($wbw; $b_wbw))" | lpad(.; 15) as $diff_bw |
        "\(calc_diff($riops; $b_riops)) / \(calc_diff($wiops; $b_wiops))" | lpad(.; 15) as $diff_iops |
        "\(calc_diff($rlat; $b_rlat)) / \(calc_diff($wlat; $b_wlat))" | lpad(.; 15) as $diff_lat |

        "\(rpad($base; 25))\t\(fmt_val($rbw))\t\(fmt_val($wbw))\t\(fmt_val($riops))\t\(fmt_val($wiops))\t\(fmt_val($rlat))\t\(fmt_val($wlat))\t\($diff_bw)\t\($diff_iops)\t\($diff_lat)"
    '
