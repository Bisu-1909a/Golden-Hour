export interface Database {
  public: {
    Tables: {
      profiles: {
        Row: {
          id: string;
          user_id: string;
          full_name: string | null;
          phone: string | null;
          emergency_contact_name: string | null;
          emergency_contact_phone: string | null;
          medical_conditions: string | null;
          allergies: string | null;
          medications: string | null;
          blood_type: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id: string;
          full_name?: string | null;
          phone?: string | null;
          emergency_contact_name?: string | null;
          emergency_contact_phone?: string | null;
          medical_conditions?: string | null;
          allergies?: string | null;
          medications?: string | null;
          blood_type?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          full_name?: string | null;
          phone?: string | null;
          emergency_contact_name?: string | null;
          emergency_contact_phone?: string | null;
          medical_conditions?: string | null;
          allergies?: string | null;
          medications?: string | null;
          blood_type?: string | null;
          created_at?: string;
          updated_at?: string;
        };
      };
      emergency_contacts: {
        Row: {
          id: string;
          user_id: string;
          name: string;
          phone: string;
          relationship: string;
          is_primary: boolean;
          created_at: string;
        };
        Insert: {
          id?: string;
          user_id: string;
          name: string;
          phone: string;
          relationship: string;
          is_primary?: boolean;
          created_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          name?: string;
          phone?: string;
          relationship?: string;
          is_primary?: boolean;
          created_at?: string;
        };
      };
      hospitals: {
        Row: {
          id: string;
          name: string;
          address: string;
          phone: string;
          latitude: number;
          longitude: number;
          emergency_department: boolean;
          trauma_level: string | null;
          specialties: string[] | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          name: string;
          address: string;
          phone: string;
          latitude: number;
          longitude: number;
          emergency_department?: boolean;
          trauma_level?: string | null;
          specialties?: string[] | null;
          created_at?: string;
        };
        Update: {
          id?: string;
          name?: string;
          address?: string;
          phone?: string;
          latitude?: number;
          longitude?: number;
          emergency_department?: boolean;
          trauma_level?: string | null;
          specialties?: string[] | null;
          created_at?: string;
        };
      };
      emergency_events: {
        Row: {
          id: string;
          user_id: string;
          event_type: string;
          location_lat: number | null;
          location_lng: number | null;
          location_address: string | null;
          status: string;
          notes: string | null;
          resolved_at: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          user_id: string;
          event_type: string;
          location_lat?: number | null;
          location_lng?: number | null;
          location_address?: string | null;
          status?: string;
          notes?: string | null;
          resolved_at?: string | null;
          created_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          event_type?: string;
          location_lat?: number | null;
          location_lng?: number | null;
          location_address?: string | null;
          status?: string;
          notes?: string | null;
          resolved_at?: string | null;
          created_at?: string;
        };
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      [_ in never]: never;
    };
    Enums: {
      [_ in never]: never;
    };
  };
}

export type Profile = Database["public"]["Tables"]["profiles"]["Row"];
export type EmergencyContact =
  Database["public"]["Tables"]["emergency_contacts"]["Row"];
export type Hospital = Database["public"]["Tables"]["hospitals"]["Row"];
export type EmergencyEvent =
  Database["public"]["Tables"]["emergency_events"]["Row"];
