void init_batch_prover(char* params_dir, char* assets_dir);
void init_batch_verifier(char* params_dir, char* assets_dir);
char* get_batch_vk();
char* check_chunk_proofs(char* chunk_proofs);
char* gen_batch_proof(char* chunk_hashes, char* chunk_proofs);
char verify_batch_proof(char* proof);

void init_chunk_prover(char* params_dir, char* assets_dir);
void init_chunk_verifier(char* params_dir, char* assets_dir);
char* get_chunk_vk();
char* gen_chunk_proof(char* chunk_trace);
char verify_chunk_proof(char* proof);

char* chunk_trace_to_chunk_info(char* chunk_trace);
void free_c_chars(char* ptr);
