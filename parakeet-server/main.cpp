// Streaming transcription server for use with audiocapture pipe.
// Reads raw float32 16kHz mono PCM from stdin, transcribes with EOU model,
// prints text as utterances complete.
//
// Usage: parakeet-server <model.safetensors> <vocab.txt> [options]
//   --gpu          Use Metal GPU
//   --fp16         Use half precision
//   --model TYPE   Model type: eou-120m (default), tdt-600m, tdt-ctc-110m
//   --chunk MS     Chunk size in milliseconds (default: 500)

#include <parakeet/parakeet.hpp>

#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

int main(int argc, char *argv[]) {
    if (argc < 3) {
        std::cerr << "Usage: " << argv[0]
                  << " <model.safetensors> <vocab.txt> [--gpu] [--fp16] "
                     "[--model TYPE] [--chunk MS]\n";
        return 1;
    }

    std::string weights_path = argv[1];
    std::string vocab_path = argv[2];
    std::string model_type = "eou-120m";
    bool use_gpu = false;
    bool use_fp16 = false;
    int chunk_ms = 500;

    for (int i = 3; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--gpu")
            use_gpu = true;
        else if (arg == "--fp16")
            use_fp16 = true;
        else if (arg == "--model" && i + 1 < argc)
            model_type = argv[++i];
        else if (arg == "--chunk" && i + 1 < argc)
            chunk_ms = std::stoi(argv[++i]);
    }

    const int sample_rate = 16000;
    const int chunk_samples = sample_rate * chunk_ms / 1000;

    if (model_type == "eou-120m") {
        // Streaming EOU model — processes audio incrementally
        auto config = parakeet::make_eou_120m_config();
        parakeet::api::StreamingTranscriber transcriber(weights_path, vocab_path,
                                                         config);
        if (use_fp16)
            transcriber.to_half();
        if (use_gpu)
            transcriber.to_gpu();

        std::cerr << "Streaming mode (EOU-120M) ready. Chunk: " << chunk_ms
                  << "ms" << std::endl;

        std::vector<float> buf(chunk_samples);

        while (true) {
            size_t bytes_read = fread(buf.data(), sizeof(float), chunk_samples,
                                      stdin);
            if (bytes_read == 0)
                break;

            auto text = transcriber.transcribe_chunk(buf.data(), bytes_read);
            if (!text.empty()) {
                std::cout << text << std::endl;
            }
        }

        // Flush remaining
        auto final_text = transcriber.get_text();
        if (!final_text.empty()) {
            std::cout << "\n[Final] " << final_text << std::endl;
        }
    } else {
        // Offline models (TDT-600M, TDT-CTC-110M) — persistent process,
        // reads WAV paths from stdin
        std::unique_ptr<parakeet::api::TDTTranscriber> tdt;
        std::unique_ptr<parakeet::api::Transcriber> tdtctc;

        if (model_type == "tdt-600m") {
            auto config = parakeet::make_tdt_600m_config();
            tdt = std::make_unique<parakeet::api::TDTTranscriber>(
                weights_path, vocab_path, config);
            if (use_fp16)
                tdt->to_half();
            if (use_gpu)
                tdt->to_gpu();
        } else if (model_type == "tdt-600m-v2") {
            auto config = parakeet::make_tdt_600m_v2_config();
            tdt = std::make_unique<parakeet::api::TDTTranscriber>(
                weights_path, vocab_path, config);
            if (use_fp16)
                tdt->to_half();
            if (use_gpu)
                tdt->to_gpu();
        } else {
            tdtctc = std::make_unique<parakeet::api::Transcriber>(
                weights_path, vocab_path);
            if (use_fp16)
                tdtctc->to_half();
            if (use_gpu)
                tdtctc->to_gpu();
        }

        std::cerr << "Persistent mode (" << model_type
                  << ") ready. Send WAV paths on stdin." << std::endl;

        std::string line;
        while (std::getline(std::cin, line)) {
            if (line.empty())
                continue;
            try {
                parakeet::api::TranscribeResult result;
                if (tdt)
                    result = tdt->transcribe(line);
                else
                    result = tdtctc->transcribe(line);
                std::cout << result.text << "\n---END---" << std::endl;
            } catch (const std::exception &e) {
                std::cout << "\n---END---" << std::endl;
                std::cerr << "Error: " << e.what() << std::endl;
            }
        }
    }

    return 0;
}
