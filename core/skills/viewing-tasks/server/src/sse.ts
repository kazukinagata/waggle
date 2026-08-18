type Listener = (data: string) => void;

export class EventBus {
  private listeners: Set<Listener> = new Set();

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  emit(data: string): void {
    for (const listener of this.listeners) {
      listener(data);
    }
  }
}
