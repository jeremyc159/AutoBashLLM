# AutoBashLLM 🤖🖥️  
*A fully‑scripted Bash agent that lets a Large‑Language‑Model drive your terminal.*

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

---

## ✨ What it does
AutoBashLLM turns ChatGPT (or another OpenAI‑compatible model) into an *interactive automation engine*:

1. You give the script a single **goal prompt** – e.g.  
   `./llm-agent.sh "Install VLC player on my Ubuntu"`
2. It sends that goal, a safety‑oriented system prompt, and the list of
   available commands to the model.
3. The model replies with a JSON plan (`"action":"run"` + array of shell
   commands).  
   The agent **executes** each command, captures stdout/stderr and feeds the
   output back to the model.
4. The conversation loops until the model replies with
   `"action":"complete"` **or** an error / turn‑limit is reached.
5. Every turn prints:
   * commands run & their output  
   * token usage  
   * live **cost estimate**

---

## 🚀 Quick Start

```bash
git clone https://github.com/your‑org/AutoBashLLM.git
cd AutoBashLLM
chmod +x llm-agent.sh

# print your openAi API key into openai.key
nano openai.key

# run a sample task
./llm-agent.sh "Investigate if any suspicious software is spying on my system"
