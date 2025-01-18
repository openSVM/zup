#!/usr/bin/env python3
import sys
import re
import matplotlib.pyplot as plt
import numpy as np
from datetime import datetime

def parse_benchmark_results(file_path):
    results = {
        'GET': [],
        'POST': [],
        'WebSocket': []
    }
    
    configs = {
        'GET': [],
        'POST': [],
        'WebSocket': []
    }
    
    current_method = None
    current_config = None
    
    with open(file_path, 'r') as f:
        for line in f:
            if '=== ' in line and ' Benchmark ===' in line:
                current_config = line.split('=== ')[1].split(' Benchmark')[0]
            elif 'Method: ' in line:
                current_method = line.split('Method: ')[1].strip()
            elif 'Requests/second:' in line:
                rps = float(re.search(r'Requests/second:\s*([\d.]+)', line).group(1))
                if current_method:
                    results[current_method].append(rps)
                    configs[current_method].append(current_config)
            elif 'WebSocket messages/second:' in line:
                mps = float(re.search(r'messages/second:\s*([\d.]+)', line).group(1))
                results['WebSocket'].append(mps)
                configs['WebSocket'].append(current_config)
    
    return results, configs

def plot_http_comparison(results, configs, output_dir):
    plt.figure(figsize=(12, 6))
    
    methods = ['GET', 'POST']
    x = np.arange(len(methods))
    width = 0.35
    
    # Calculate averages for basic and high concurrency tests
    basic_means = []
    high_means = []
    
    for method in methods:
        basic_rps = [rps for rps, cfg in zip(results[method], configs[method]) 
                    if 'Basic' in cfg]
        high_rps = [rps for rps, cfg in zip(results[method], configs[method]) 
                   if 'High Concurrency' in cfg]
        
        basic_means.append(np.mean(basic_rps) if basic_rps else 0)
        high_means.append(np.mean(high_rps) if high_rps else 0)
    
    plt.bar(x - width/2, basic_means, width, label='Basic (100 connections)')
    plt.bar(x + width/2, high_means, width, label='High Concurrency (1000 connections)')
    
    plt.xlabel('HTTP Method')
    plt.ylabel('Requests per Second')
    plt.title('HTTP Performance Comparison')
    plt.xticks(x, methods)
    plt.legend()
    plt.grid(True, linestyle='--', alpha=0.7)
    
    plt.savefig(f'{output_dir}/http_comparison.png')
    plt.close()

def plot_websocket_performance(results, output_dir):
    if not results['WebSocket']:
        return
        
    plt.figure(figsize=(8, 6))
    
    plt.bar(['WebSocket'], [np.mean(results['WebSocket'])], color='blue')
    plt.ylabel('Messages per Second')
    plt.title('WebSocket Performance')
    plt.grid(True, linestyle='--', alpha=0.7)
    
    plt.savefig(f'{output_dir}/websocket_performance.png')
    plt.close()

def plot_timeline(results, configs, output_dir):
    plt.figure(figsize=(15, 6))
    
    all_results = []
    labels = []
    colors = []
    
    for method in ['GET', 'POST', 'WebSocket']:
        for rps, cfg in zip(results[method], configs[method]):
            all_results.append(rps)
            labels.append(f'{method}\n{cfg}')
            colors.append('blue' if method == 'GET' else 
                        'green' if method == 'POST' else 'red')
    
    plt.bar(range(len(all_results)), all_results, color=colors)
    plt.xticks(range(len(all_results)), labels, rotation=45, ha='right')
    plt.ylabel('Requests/Messages per Second')
    plt.title('Performance Timeline')
    plt.grid(True, linestyle='--', alpha=0.7)
    
    plt.tight_layout()
    plt.savefig(f'{output_dir}/performance_timeline.png')
    plt.close()

def main():
    if len(sys.argv) != 2:
        print("Usage: python plot_benchmarks.py <benchmark_report_file>")
        sys.exit(1)
    
    report_file = sys.argv[1]
    output_dir = '/'.join(report_file.split('/')[:-1])
    
    results, configs = parse_benchmark_results(report_file)
    
    # Generate plots
    plot_http_comparison(results, configs, output_dir)
    plot_websocket_performance(results, output_dir)
    plot_timeline(results, configs, output_dir)
    
    # Save raw data as CSV
    with open(f'{output_dir}/benchmark_data.csv', 'w') as f:
        f.write('Method,Configuration,RequestsPerSecond\n')
        for method in results:
            for rps, cfg in zip(results[method], configs[method]):
                f.write(f'{method},{cfg},{rps}\n')

if __name__ == '__main__':
    main()
