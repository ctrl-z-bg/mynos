int main() {
  while(1) {
    __asm__ volatile ("int $0x50\n");
  }
  return 1;
}
