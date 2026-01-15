import { create } from 'zustand';

interface HomeState {
  selectedHomeId: string | null;
  setSelectedHomeId: (homeId: string | null) => void;
}

export const useHomeStore = create<HomeState>((set) => ({
  selectedHomeId: null,
  setSelectedHomeId: (homeId) => set({ selectedHomeId: homeId }),
}));
