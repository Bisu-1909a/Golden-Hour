export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type EmergencyCategory =
  | 'chest_pain'
  | 'stroke_signs'
  | 'severe_bleeding'
  | 'severe_breathlessness'

export type AlertStatus =
  | 'created'
  | 'acknowledged'
  | 'ready'
  | 'arrived'
  | 'closed'
  | 'diverted'
  | 'cancelled'

export type TaskStatus =
  | 'unclaimed'
  | 'claimed'
  | 'completed'

export type TaskRole =
  | 'reception'
  | 'doctor'
  | 'nurse'
  | 'pharmacy'
  | 'equipment'
  | 'transport'
  | 'counter'
  | 'in_charge'
  | 'admin'

export type EscalationLevel =
  | 'normal'
  | 'amber'
  | 'red'

export type RefusalReason =
  | 'no_bed'
  | 'no_team'
  | 'equipment_unavailable'
  | 'at_capacity'
  | 'other'

export interface Database {
  public: {
    Tables: {
      hospitals: {
        Row: {
          id: string
          code: string
          name: string
          short_name: string
          district: string
          state: string
          address: string
          latitude: number
          longitude: number
          phone_number: string
          emergency_phone: string
          entrance_notes: string | null
          is_active: boolean
          created_at: string
          updated_at: string
        }
        Insert: {
          id?: string
          code: string
          name: string
          short_name: string
          district?: string
          state?: string
          address: string
          latitude: number
          longitude: number
          phone_number: string
          emergency_phone: string
          entrance_notes?: string | null
          is_active?: boolean
          created_at?: string
          updated_at?: string
        }
        Update: {
          id?: string
          code?: string
          name?: string
          short_name?: string
          district?: string
          state?: string
          address?: string
          latitude?: number
          longitude?: number
          phone_number?: string
          emergency_phone?: string
          entrance_notes?: string | null
          is_active?: boolean
          created_at?: string
          updated_at?: string
        }
      }
      hospital_capabilities: {
        Row: {
          id: string
          hospital_id: string
          category: EmergencyCategory
          is_available: boolean
          ct_scanner_active: boolean
          cath_lab_active: boolean
          blood_bank_active: boolean
          ventilator_active: boolean
          oxygen_supply_active: boolean
          last_confirmed_at: string
          confirmed_by: string
          updated_at: string
        }
        Insert: {
          id?: string
          hospital_id: string
          category: EmergencyCategory
          is_available?: boolean
          ct_scanner_active?: boolean
          cath_lab_active?: boolean
          blood_bank_active?: boolean
          ventilator_active?: boolean
          oxygen_supply_active?: boolean
          last_confirmed_at?: string
          confirmed_by?: string
          updated_at?: string
        }
        Update: {
          id?: string
          hospital_id?: string
          category?: EmergencyCategory
          is_available?: boolean
          ct_scanner_active?: boolean
          cath_lab_active?: boolean
          blood_bank_active?: boolean
          ventilator_active?: boolean
          oxygen_supply_active?: boolean
          last_confirmed_at?: string
          confirmed_by?: string
          updated_at?: string
        }
      }
      hospital_resources: {
        Row: {
          id: string
          hospital_id: string
          total_emergency_beds: number
          available_emergency_beds: number
          held_beds: number
          active_teams_count: number
          last_updated_at: string
          updated_by: string | null
        }
        Insert: {
          id?: string
          hospital_id: string
          total_emergency_beds?: number
          available_emergency_beds?: number
          held_beds?: number
          active_teams_count?: number
          last_updated_at?: string
          updated_by?: string | null
        }
        Update: {
          id?: string
          hospital_id?: string
          total_emergency_beds?: number
          available_emergency_beds?: number
          held_beds?: number
          active_teams_count?: number
          last_updated_at?: string
          updated_by?: string | null
        }
      }
      staff_members: {
        Row: {
          id: string
          hospital_id: string
          name: string
          role: TaskRole
          pin_hash: string
          is_duty_lead: boolean
          is_active: boolean
          created_at: string
          updated_at: string
        }
        Insert: {
          id?: string
          hospital_id: string
          name: string
          role: TaskRole
          pin_hash: string
          is_duty_lead?: boolean
          is_active?: boolean
          created_at?: string
          updated_at?: string
        }
        Update: {
          id?: string
          hospital_id?: string
          name?: string
          role?: TaskRole
          pin_hash?: string
          is_duty_lead?: boolean
          is_active?: boolean
          created_at?: string
          updated_at?: string
        }
      }
      task_templates: {
        Row: {
          id: string
          hospital_id: string | null
          category: EmergencyCategory
          task_sequence: number
          role_required: TaskRole
          title_en: string
          title_or: string
          instructions_en: string | null
          instructions_or: string | null
          created_at: string
        }
        Insert: {
          id?: string
          hospital_id?: string | null
          category: EmergencyCategory
          task_sequence: number
          role_required: TaskRole
          title_en: string
          title_or: string
          instructions_en?: string | null
          instructions_or?: string | null
          created_at?: string
        }
        Update: {
          id?: string
          hospital_id?: string | null
          category?: EmergencyCategory
          task_sequence?: number
          role_required?: TaskRole
          title_en?: string
          title_or?: string
          instructions_en?: string | null
          instructions_or?: string | null
          created_at?: string
        }
      }
      alerts: {
        Row: {
          id: string
          alert_code: string
          access_token: string
          hospital_id: string
          category: EmergencyCategory
          status: AlertStatus
          origin_latitude: number | null
          origin_longitude: number | null
          origin_area_name: string | null
          estimated_distance_km: number | null
          estimated_drive_minutes: number | null
          bed_held: boolean
          bed_held_expires_at: string | null
          diversion_reason: RefusalReason | null
          diversion_notes: string | null
          diverted_to_hospital_id: string | null
          cancellation_reason: string | null
          created_at: string
          acknowledged_at: string | null
          all_tasks_claimed_at: string | null
          arrived_at: string | null
          closed_at: string | null
          closed_by: string | null
          closure_summary: string | null
          client_request_id: string | null
        }
        Insert: {
          id?: string
          alert_code?: string
          access_token?: string
          hospital_id: string
          category: EmergencyCategory
          status?: AlertStatus
          origin_latitude?: number | null
          origin_longitude?: number | null
          origin_area_name?: string | null
          estimated_distance_km?: number | null
          estimated_drive_minutes?: number | null
          bed_held?: boolean
          bed_held_expires_at?: string | null
          diversion_reason?: RefusalReason | null
          diversion_notes?: string | null
          diverted_to_hospital_id?: string | null
          cancellation_reason?: string | null
          created_at?: string
          acknowledged_at?: string | null
          all_tasks_claimed_at?: string | null
          arrived_at?: string | null
          closed_at?: string | null
          closed_by?: string | null
          closure_summary?: string | null
          client_request_id?: string | null
        }
        Update: {
          id?: string
          alert_code?: string
          access_token?: string
          hospital_id?: string
          category?: EmergencyCategory
          status?: AlertStatus
          origin_latitude?: number | null
          origin_longitude?: number | null
          origin_area_name?: string | null
          estimated_distance_km?: number | null
          estimated_drive_minutes?: number | null
          bed_held?: boolean
          bed_held_expires_at?: string | null
          diversion_reason?: RefusalReason | null
          diversion_notes?: string | null
          diverted_to_hospital_id?: string | null
          cancellation_reason?: string | null
          created_at?: string
          acknowledged_at?: string | null
          all_tasks_claimed_at?: string | null
          arrived_at?: string | null
          closed_at?: string | null
          closed_by?: string | null
          closure_summary?: string | null
          client_request_id?: string | null
        }
      }
      alert_tasks: {
        Row: {
          id: string
          alert_id: string
          task_sequence: number
          role_required: TaskRole
          title_en: string
          title_or: string
          status: TaskStatus
          claimed_by: string | null
          claimed_by_name: string | null
          claimed_at: string | null
          completed_at: string | null
          escalation_level: EscalationLevel
          amber_escalated_at: string | null
          red_escalated_at: string | null
          created_at: string
          updated_at: string
        }
        Insert: {
          id?: string
          alert_id: string
          task_sequence: number
          role_required: TaskRole
          title_en: string
          title_or: string
          status?: TaskStatus
          claimed_by?: string | null
          claimed_by_name?: string | null
          claimed_at?: string | null
          completed_at?: string | null
          escalation_level?: EscalationLevel
          amber_escalated_at?: string | null
          red_escalated_at?: string | null
          created_at?: string
          updated_at?: string
        }
        Update: {
          id?: string
          alert_id?: string
          task_sequence?: number
          role_required?: TaskRole
          title_en?: string
          title_or?: string
          status?: TaskStatus
          claimed_by?: string | null
          claimed_by_name?: string | null
          claimed_at?: string | null
          completed_at?: string | null
          escalation_level?: EscalationLevel
          amber_escalated_at?: string | null
          red_escalated_at?: string | null
          created_at?: string
          updated_at?: string
        }
      }
      audit_logs: {
        Row: {
          id: number
          alert_id: string
          action: string
          actor_type: string
          actor_id: string | null
          actor_role: string | null
          details: Json
          created_at: string
        }
        Insert: {
          id?: number
          alert_id: string
          action: string
          actor_type: string
          actor_id?: string | null
          actor_role?: string | null
          details?: Json
          created_at?: string
        }
        Update: never // Append-only constraint: Updates strictly forbidden
      }
    }
    Views: {
      v_active_alerts_escalation: {
        Row: {
          alert_id: string
          alert_code: string
          hospital_id: string
          hospital_name: string
          category: EmergencyCategory
          alert_status: AlertStatus
          estimated_distance_km: number | null
          estimated_drive_minutes: number | null
          created_at: string
          arrived_at: string | null
          elapsed_seconds: number
          total_tasks: number
          claimed_tasks_count: number
          unclaimed_tasks_count: number
          visual_status: 'NORMAL' | 'AMBER' | 'RED' | 'ALL_TAKEN' | 'ARRIVED' | 'CLOSED'
          display_badge: string
        }
      }
    }
    Functions: {
      claim_task: {
        Args: {
          p_task_id: string
          p_staff_id: string
        }
        Returns: Json
      }
      evaluate_alert_escalations: {
        Args: {
          p_alert_id?: string
        }
        Returns: {
          alert_id: string
          alert_code: string
          elapsed_seconds: number
          unclaimed_tasks: number
          new_escalation: string
        }[]
      }
      generate_unique_alert_code: {
        Args: Record<string, never>
        Returns: string
      }
    }
  }
}

// Model exports for GoldenHour
export type Hospital = Database['public']['Tables']['hospitals']['Row']
export type HospitalCapability = Database['public']['Tables']['hospital_capabilities']['Row']
export type HospitalResource = Database['public']['Tables']['hospital_resources']['Row']
export type StaffMember = Database['public']['Tables']['staff_members']['Row']
export type TaskTemplate = Database['public']['Tables']['task_templates']['Row']
export type Alert = Database['public']['Tables']['alerts']['Row']
export type AlertTask = Database['public']['Tables']['alert_tasks']['Row']
export type AuditLog = Database['public']['Tables']['audit_logs']['Row']
export type ActiveAlertEscalation = Database['public']['Views']['v_active_alerts_escalation']['Row']
