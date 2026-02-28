import { spawn } from 'child_process';
import { logoutAgent } from '../mindcraft/mindserver.js';

export class AgentProcess {
    constructor(name, port, remoteUrl = null, settingsFile = null) {
        this.name = name;
        this.port = port;
        this.remoteUrl = remoteUrl;
        this.settingsFile = settingsFile;
    }

    start(load_memory=false, init_message=null, count_id=0) {
        this.count_id = count_id;
        this.running = true;

        let args = ['src/process/init_agent.js', this.name];
        args.push('-n', this.name);
        args.push('-c', count_id);
        if (load_memory)
            args.push('-l', load_memory);
        if (init_message)
            args.push('-m', init_message);
        if (this.remoteUrl) {
            args.push('-u', this.remoteUrl);
            args.push('-s', this.settingsFile);
        } else {
            args.push('-p', this.port);
        }

        const agentProcess = spawn(process.execPath, args, {
            stdio: 'inherit',
            stderr: 'inherit',
        });
        
        let last_restart = Date.now();
        agentProcess.on('exit', (code, signal) => {
            console.log(`Agent process exited with code ${code} and signal ${signal}`);
            this.running = false;
            logoutAgent(this.name);
            
            if (code > 1) {
                console.log(`Ending task`);
                process.exit(code);
            }

            if (code !== 0 && signal !== 'SIGINT') {
                // agent must run for at least 10 seconds before restarting
                if (Date.now() - last_restart < 10000) {
                    this._quickExits = (this._quickExits || 0) + 1
                    if (this._quickExits > 3) {
                        console.error('Agent crashed 3+ times rapidly. Stopping restarts.')
                        return
                    }
                    const delay = this._quickExits * 10000
                    console.log(`Agent exited quickly (${this._quickExits}/3). Retrying in ${delay / 1000}s...`)
                    setTimeout(() => this.start(true, 'Agent process restarted.', count_id), delay)
                    return
                }
                this._quickExits = 0
                console.log('Restarting agent...');
                this.start(true, 'Agent process restarted.', count_id, this.port);
                last_restart = Date.now();
            }
        });
    
        agentProcess.on('error', (err) => {
            console.error('Agent process error:', err);
        });

        this.process = agentProcess;
    }

    stop() {
        if (!this.running) return;
        this.process.kill('SIGINT');
    }

    forceRestart() {
        if (this.running && this.process && !this.process.killed) {
            console.log(`Agent process for ${this.name} is still running. Attempting to force restart.`);
            
            const restartTimeout = setTimeout(() => {
                console.warn(`Agent ${this.name} did not stop in time. It might be stuck.`);
            }, 5000); // 5 seconds to exit

            this.process.once('exit', () => {
                 clearTimeout(restartTimeout);
                 console.log(`Stopped hanging agent ${this.name}. Now restarting.`);
                 this.start(true, 'Agent process restarted.', this.count_id);
            });
            this.stop(); // sends SIGINT
        } else {
             this.start(true, 'Agent process restarted.', this.count_id);
        }
    }
}