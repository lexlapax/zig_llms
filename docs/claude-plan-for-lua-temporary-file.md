  I will create a comprehensive security sandboxing design document for the zig_llms Lua scripting engine. Based on my research, I'll provide:

     1. Security Threat Analysis: Common Lua vulnerabilities, attack vectors, and sandbox escape techniques
     2. Multi-Layer Security Architecture: Integration with existing zig_llms SecurityPermissions and SandboxLevel systems
     3. Environment Isolation Strategy: _ENV manipulation, global table restrictions, and function whitelisting
     4. Bytecode Security: Validation, prevention of malicious bytecode, and safe loading mechanisms
     5. Resource Management: Memory limits, CPU time constraints, instruction counting with lua_sethook
     6. Module Loading Security: Safe require() implementation and custom loaders
     7. Metatable Protection: Preventing __index/__newindex sandbox escapes
     8. String Pattern Safety: ReDoS prevention and pattern matching security
     9. Implementation Integration: How to integrate with existing zig_llms security framework
     10. Performance Optimization: Balancing security with performance

     The design will focus on practical, production-ready patterns that can be directly implemented in the Lua engine while maintaining compatibility with the 
     existing scripting infrastructure.
     +11 more tool uses